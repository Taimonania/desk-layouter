#!/bin/zsh
set -eu

# Release pipeline for Desk Layouter — issue #44 (Phase 1 of #43).
#
# Takes the app from source to a publicly downloadable, signed, notarized,
# stapled .dmg on GitHub Releases, then proves the release is actually live.
#
# Philosophy mirrors the repo's other verification harnesses
# (verify-desktop-placement.sh, verify-session-boundary.sh): produce a real
# artifact, then assert against OBSERVABLE reality — never against "did we call
# codesign". Each stage is a function and the verify stages run independently.
#
# Subcommands:
#   preflight         Assert every tool + credential the pipeline needs exists;
#                     report ALL that are missing at once. Reads nothing, writes
#                     nothing, publishes nothing.
#   build             Build a universal (arm64 + x86_64) .app via build-app.sh.
#   sign              Sign the .app inside-out (Developer ID, hardened runtime,
#                     secure timestamp, never --deep).
#   package           Assemble a signed .dmg via create-dmg and record a manifest.
#   notarize          Submit the .dmg to Apple notary service and wait.
#   staple            Staple the notarization ticket to the .dmg.
#   publish           Create the GitHub Release and upload the .dmg. IRREVERSIBLE
#                     and public — refuses unless RELEASE_PUBLISH=1.
#   verify            verify-local + verify-available.
#   verify-local      Assert the local artifact: codesign --verify --strict,
#                     Developer ID identity + hardened runtime, spctl, stapler.
#   verify-available  Assert each published asset URL returns 200 and its
#                     checksum matches the local artifact.
#   all               preflight → build → sign → package → notarize → staple →
#                     (publish, if RELEASE_PUBLISH=1) → verify.
#
# Manual, human-only prerequisites this script CONSUMES (it never creates them):
#   * Apple Developer Program membership.
#   * A "Developer ID Application" certificate in the login keychain
#     (override selection with DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)").
#   * A stored notarytool credential profile (see NOTARY_KEYCHAIN_PROFILE),
#     created once via: xcrun notarytool store-credentials.
#   * create-dmg (brew install create-dmg).
#   * gh authenticated with push access to the release repo.
# See docs/releasing.md.

repo_dir="${0:A:h:h}"
build_app_script="${0:A:h}/build-app.sh"
info_plist="$repo_dir/App/Info.plist"

release_repo="${RELEASE_REPO:-Taimonania/desk-layouter}"
notary_profile="${NOTARY_KEYCHAIN_PROFILE:-DeskLayouterNotary}"
release_dir="$repo_dir/.build/release"
app_bundle="$repo_dir/.build/Desk Layouter.app"
manifest="$release_dir/manifest.json"
notes_file="${RELEASE_NOTES_FILE:-$repo_dir/RELEASE_NOTES.md}"

usage() {
    print -u2 "usage: $0 {preflight|build|sign|package|notarize|staple|publish|verify|verify-local|verify-available|all}"
    exit 2
}

die() { print -u2 "release: $1"; exit 1; }

# CFBundleShortVersionString is the single source of truth for the version; the
# tag and .dmg name are derived from it so they can never drift (AC: version ==
# tag). Read the plist once here rather than re-spawning PlistBuddy per use.
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
release_tag="v$release_version"
dmg_file="$release_dir/DeskLayouter-$release_version.dmg"

# Resolve the Developer ID Application signing identity. Honors an explicit
# override; otherwise auto-detects a single matching identity in the keychain
# and refuses ambiguously when more than one is present.
resolve_identity() {
    if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
        print "$DEVELOPER_ID_APPLICATION"
        return 0
    fi
    local found
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' || true)
    local count
    count=$(printf '%s\n' "$found" | grep -c 'Developer ID Application' || true)
    if [[ "$count" -eq 0 ]]; then
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        print -u2 "release: multiple Developer ID Application identities found; set DEVELOPER_ID_APPLICATION to pick one:"
        printf '%s\n' "$found" >&2
        return 2
    fi
    # Extract the quoted identity name from `security find-identity` output.
    printf '%s\n' "$found" | sed -E 's/.*"(.*)".*/\1/'
}

# --- preflight ------------------------------------------------------------

do_preflight() {
    local missing=()

    local tool
    for tool in swift codesign xcrun create-dmg gh shasum curl jq; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("tool: $tool")
    done
    command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 || missing+=("tool: PlistBuddy")
    xcrun --find notarytool >/dev/null 2>&1 || missing+=("tool: xcrun notarytool")
    xcrun --find stapler >/dev/null 2>&1 || missing+=("tool: xcrun stapler")

    local identity_status=0
    resolve_identity >/dev/null 2>&1 || identity_status=$?
    if [[ "$identity_status" -eq 1 ]]; then
        missing+=("credential: Developer ID Application certificate (none in keychain)")
    elif [[ "$identity_status" -eq 2 ]]; then
        missing+=("credential: DEVELOPER_ID_APPLICATION must disambiguate multiple identities")
    fi

    if command -v gh >/dev/null 2>&1; then
        # Scope to the host the release repo lives on; a stale token for an
        # unrelated account must not fail an otherwise-authenticated github.com.
        gh auth status --hostname github.com >/dev/null 2>&1 \
            || missing+=("auth: gh is not authenticated for github.com (gh auth login)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print -u2 "release: preflight FAILED — missing prerequisites:"
        local item
        for item in "${missing[@]}"; do
            print -u2 "  - $item"
        done
        print -u2 ""
        print -u2 "See docs/releasing.md for how to provide each. The notary credential"
        print -u2 "profile '$notary_profile' is validated when 'notarize' runs."
        return 1
    fi

    print "release: preflight OK"
    print "  version:        $release_version (tag $release_tag)"
    print "  signing identity: $(resolve_identity)"
    print "  release repo:   $release_repo"
    print "  notary profile: $notary_profile"
}

# --- build ----------------------------------------------------------------

do_build() {
    print "release: building universal .app (arm64 + x86_64)..."
    # Export the identity so build-app.sh re-signs Sparkle's nested helpers and
    # the framework inside-out during the build. do_sign then re-signs only the
    # outer binary + app bundle (idempotent). If no single identity resolves we
    # build un-signed and let do_sign surface the error, exactly as before.
    local build_identity
    if build_identity=$(resolve_identity 2>/dev/null); then
        DEVELOPER_ID_APPLICATION="$build_identity" \
            RELEASE_ARCHS="arm64 x86_64" CONFIGURATION=release "$build_app_script" >/dev/null
    else
        RELEASE_ARCHS="arm64 x86_64" CONFIGURATION=release "$build_app_script" >/dev/null
    fi
    [[ -d "$app_bundle" ]] || die "build did not produce $app_bundle"

    local archs
    archs=$(lipo -archs "$app_bundle/Contents/MacOS/DeskLayouter" 2>/dev/null || true)
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) print "release: universal binary OK ($archs)" ;;
        *) die "expected a universal binary, got: '$archs'" ;;
    esac
}

# --- sign -----------------------------------------------------------------

do_sign() {
    local identity
    identity=$(resolve_identity) || die "no Developer ID Application identity (run preflight)"
    [[ -d "$app_bundle" ]] || die "no .app to sign; run 'build' first"

    print "release: signing inside-out with '$identity' (hardened runtime, secure timestamp)..."
    # Inside-out: sign nested code before the enclosing bundle, never --deep.
    # Phase 1 has only the main executable nested in the bundle; Phase 2 (#45)
    # extends this to Sparkle's helpers/XPC in build-app.sh.
    codesign --force --options runtime --timestamp \
        --sign "$identity" "$app_bundle/Contents/MacOS/DeskLayouter"
    codesign --force --options runtime --timestamp \
        --sign "$identity" "$app_bundle"

    codesign --verify --strict --verbose=2 "$app_bundle" \
        || die "signature verification failed immediately after signing"
    print "release: signed OK"
}

# --- package --------------------------------------------------------------

do_package() {
    local identity
    identity=$(resolve_identity) || die "no Developer ID Application identity (run preflight)"
    [[ -d "$app_bundle" ]] || die "no .app to package; run 'build' and 'sign' first"

    mkdir -p "$release_dir"
    local dmg="$dmg_file"
    rm -f "$dmg"

    print "release: packaging $dmg via create-dmg..."
    # create-dmg exits non-zero when it cannot detach a leftover device even on
    # otherwise-successful runs; treat "the .dmg exists" as the success signal.
    create-dmg \
        --volname "Desk Layouter" \
        --app-drop-link 480 170 \
        --icon "Desk Layouter.app" 160 170 \
        --window-size 640 360 \
        --codesign "$identity" \
        "$dmg" "$app_bundle" || true
    [[ -f "$dmg" ]] || die "create-dmg did not produce $dmg"

    write_manifest "$dmg"
    print "release: packaged OK -> $dmg"
}

write_manifest() {
    local dmg="$1" checksum
    checksum=$(shasum -a 256 "$dmg" | awk '{print $1}')
    mkdir -p "$release_dir"
    jq -n \
        --arg version "$release_version" \
        --arg tag "$release_tag" \
        --arg repo "$release_repo" \
        --arg app "$app_bundle" \
        --arg dmg "$dmg" \
        --arg dmg_name "$(basename "$dmg")" \
        --arg dmg_sha256 "$checksum" \
        '{version:$version, tag:$tag, repo:$repo, app:$app, dmg:$dmg, dmg_name:$dmg_name, dmg_sha256:$dmg_sha256}' \
        > "$manifest"
}

manifest_field() {
    [[ -f "$manifest" ]] || die "no manifest at $manifest; run 'package' first"
    jq -r --arg k "$1" '.[$k] // empty' "$manifest"
}

# --- notarize / staple ----------------------------------------------------

do_notarize() {
    local dmg
    dmg=$(manifest_field dmg)
    [[ -f "$dmg" ]] || die "no .dmg at $dmg; run 'package' first"
    print "release: submitting $dmg to notary service (profile '$notary_profile'); this waits for Apple..."
    local out
    out=$(xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait 2>&1) \
        || { printf '%s\n' "$out" >&2; die "notarization submission failed (check the profile '$notary_profile')"; }
    printf '%s\n' "$out"
    # `notarytool submit --wait` can exit 0 even when the final status is
    # Invalid/Rejected, so assert Accepted explicitly rather than trusting exit.
    printf '%s\n' "$out" | grep -q 'status: Accepted' \
        || die "notarization did not reach status Accepted; inspect with: xcrun notarytool log <id> --keychain-profile $notary_profile"
    print "release: notarized OK"
}

do_staple() {
    local dmg
    dmg=$(manifest_field dmg)
    [[ -f "$dmg" ]] || die "no .dmg at $dmg; run 'package' first"
    xcrun stapler staple "$dmg" || die "stapling failed"
    # Stapling rewrites the .dmg in place, so the checksum recorded at package
    # time is now stale. Refresh the manifest to the bytes we actually publish,
    # or verify-available would compare the downloaded (stapled) .dmg against a
    # pre-staple hash and always fail.
    write_manifest "$dmg"
    print "release: stapled OK"
}

# --- publish (irreversible, public) ---------------------------------------

do_publish() {
    if [[ "${RELEASE_PUBLISH:-0}" != "1" ]]; then
        die "publish is irreversible and public; re-run with RELEASE_PUBLISH=1 to create the GitHub Release"
    fi
    local dmg tag version
    dmg=$(manifest_field dmg)
    tag=$(manifest_field tag)
    version=$(manifest_field version)
    [[ -f "$dmg" ]] || die "no .dmg to publish; run the earlier stages first"

    [[ -f "$notes_file" ]] || die "release notes not found at $notes_file (see docs/releasing.md for the Highlights/Notes template)"
    grep -q '^## Highlights' "$notes_file" || die "release notes must contain a '## Highlights' section"
    grep -q '^## Notes' "$notes_file" || die "release notes must contain a '## Notes' section"

    print "release: creating GitHub Release $tag on $release_repo..."
    gh release create "$tag" "$dmg" \
        --repo "$release_repo" \
        --title "Desk Layouter $version" \
        --notes-file "$notes_file" \
        --latest \
        || die "gh release create failed"
    print "release: published $tag"
}

# --- verify ---------------------------------------------------------------

do_verify_local() {
    local app dmg
    app=$(manifest_field app)
    dmg=$(manifest_field dmg)
    [[ -d "$app" ]] || die "no .app at $app; run the build/sign stages first"
    [[ -f "$dmg" ]] || die "no .dmg at $dmg; run 'package' first"

    local failed=0

    print "verify-local: codesign --verify --strict --deep"
    codesign --verify --strict --deep --verbose=2 "$app" || { print -u2 "  FAIL"; failed=1; }

    print "verify-local: Developer ID identity + hardened runtime"
    local desc
    desc=$(codesign -dvvv "$app" 2>&1 || true)
    printf '%s\n' "$desc" | grep -q 'Authority=Developer ID Application' \
        || { print -u2 "  FAIL: not signed with a Developer ID Application authority"; failed=1; }
    printf '%s\n' "$desc" | grep -Eq 'flags=.*runtime' \
        || { print -u2 "  FAIL: hardened runtime flag not set"; failed=1; }

    print "verify-local: Gatekeeper (spctl)"
    spctl -a -vvv --type install "$dmg" 2>&1 || { print -u2 "  FAIL: Gatekeeper rejected the artifact"; failed=1; }

    print "verify-local: stapled ticket (stapler validate)"
    xcrun stapler validate "$dmg" || { print -u2 "  FAIL: no stapled notarization ticket"; failed=1; }

    if (( failed )); then die "verify-local FAILED"; fi
    print "verify-local: PASS"
}

do_verify_available() {
    local tag repo local_dmg local_sha
    tag=$(manifest_field tag)
    repo=$(manifest_field repo)
    local_dmg=$(manifest_field dmg)
    local_sha=$(manifest_field dmg_sha256)

    print "verify-available: release $tag on $repo must be published, tagged latest, downloadable..."
    # Assert the release exists and is a real (non-draft, non-prerelease) publish.
    # `gh release view` has no isLatest field, so "flagged latest" is asserted
    # separately against GitHub's computed latest-release endpoint.
    local flags
    flags=$(gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease -q '"\(.isDraft) \(.isPrerelease)"' 2>/dev/null) \
        || die "release $tag is not published on $repo (run 'publish' first)"
    [[ "$flags" == "false false" ]] || die "release $tag is a draft or prerelease ($flags)"
    local latest_tag
    latest_tag=$(gh api "repos/$repo/releases/latest" -q '.tag_name' 2>/dev/null || true)
    [[ "$latest_tag" == "$tag" ]] || die "release $tag is not the latest release (latest is '${latest_tag:-none}')"

    local urls
    urls=$(gh release view "$tag" --repo "$repo" --json assets -q '.assets[].url')
    [[ -n "$urls" ]] || die "release $tag has no assets"

    local failed=0 url code
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        code=$(curl -sIL -o /dev/null -w '%{http_code}' "$url" || echo 000)
        if [[ "$code" == "200" ]]; then
            print "  200 OK  $url"
        else
            print -u2 "  FAIL ($code)  $url"
            failed=1
        fi
    done <<< "$urls"

    print "verify-available: downloaded checksum must match the local artifact..."
    local tmp remote_sha
    tmp=$(mktemp -d)
    curl -sL -o "$tmp/asset.dmg" \
        "$(printf '%s\n' "$urls" | grep -i '\.dmg' | head -n1)" || true
    if [[ -s "$tmp/asset.dmg" ]]; then
        remote_sha=$(shasum -a 256 "$tmp/asset.dmg" | awk '{print $1}')
        if [[ "$remote_sha" == "$local_sha" ]]; then
            print "  checksum matches ($remote_sha)"
        else
            print -u2 "  FAIL: published checksum $remote_sha != local $local_sha"
            failed=1
        fi
    else
        print -u2 "  FAIL: could not download the published .dmg"
        failed=1
    fi
    rm -rf "$tmp"

    if (( failed )); then die "verify-available FAILED"; fi
    print "verify-available: PASS"
}

do_verify() {
    do_verify_local
    do_verify_available
}

# --- all ------------------------------------------------------------------

do_all() {
    do_preflight
    do_build
    do_sign
    do_package
    do_notarize
    do_staple
    if [[ "${RELEASE_PUBLISH:-0}" == "1" ]]; then
        do_publish
        do_verify
    else
        print "release: RELEASE_PUBLISH != 1 — built, signed, notarized, stapled locally but NOT published."
        do_verify_local
        print "release: to publish and verify availability, re-run with RELEASE_PUBLISH=1."
    fi
}

# --- dispatch -------------------------------------------------------------

(( $# == 1 )) || usage
case "$1" in
    preflight) do_preflight ;;
    build) do_build ;;
    sign) do_sign ;;
    package) do_package ;;
    notarize) do_notarize ;;
    staple) do_staple ;;
    publish) do_publish ;;
    verify) do_verify ;;
    verify-local) do_verify_local ;;
    verify-available) do_verify_available ;;
    all) do_all ;;
    *) usage ;;
esac
