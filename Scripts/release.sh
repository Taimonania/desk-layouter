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
#   staple            Staple the notarization ticket to the .dmg and the .app
#                     (so the Sparkle update zip carries an offline ticket).
#   appcast           Zip the signed/stapled .app for Sparkle and generate an
#                     EdDSA-signed appcast.xml pointing at the Release download
#                     URLs. Signs but publishes nothing.
#   notes             Print the exact GitHub release notes for this version to
#                     stdout (Highlights from CHANGELOG.md + the static Notes
#                     footer). Builds and publishes nothing — the review artifact
#                     to approve before publishing.
#   publish           Create the GitHub Release (uploads the .dmg AND the update
#                     .zip) and deploy appcast.xml to GitHub Pages so it is
#                     reachable at SUFeedURL. IRREVERSIBLE and public — refuses
#                     unless RELEASE_PUBLISH=1.
#   verify            verify-local + verify-available.
#   verify-local      Assert the local artifact: codesign --verify --strict,
#                     Developer ID identity + hardened runtime, spctl, stapler.
#   verify-available  Assert each published asset URL returns 200 and its
#                     checksum matches the local artifact, and that the appcast
#                     at SUFeedURL returns 200, parses as XML, has a non-empty
#                     sparkle:edSignature on its newest enclosure, and that
#                     enclosure's URL returns 200.
#   all               preflight → build → sign → package → notarize → staple →
#                     appcast → (publish, if RELEASE_PUBLISH=1) → verify.
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
# CHANGELOG.md is the single source of truth for release notes (issue #73): the
# app bundles it for the What's-New screen AND this pipeline derives each GitHub
# release's notes from the matching `## <version> — <date>` section. There is no
# separate RELEASE_NOTES.md any more.
changelog_file="$repo_dir/CHANGELOG.md"

die() { print -u2 "release: $1"; exit 1; }

usage() {
    print -u2 "usage: $0 {preflight|build|sign|package|notarize|staple|appcast|notes|publish|verify|verify-local|verify-available|all}"
    exit 2
}

# generate_appcast is vendored by SPM under the Sparkle artifact bundle; resolve
# it relative to the package rather than hardcoding a brittle absolute path.
sparkle_bin_dir="$repo_dir/.build/artifacts/sparkle/Sparkle/bin"
# The SUFeedURL baked into Info.plist by #45 is the single source of truth for
# where the appcast must be reachable; read it here so the publish and verify
# stages can never drift from what installed builds actually poll. Fail with a
# clear message rather than a raw PlistBuddy error if the key is somehow absent.
feed_url=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist" 2>/dev/null) \
    || die "SUFeedURL missing from $info_plist (baked in by #45); cannot resolve the appcast feed"

# CFBundleShortVersionString is the single source of truth for the version; the
# tag and .dmg name are derived from it so they can never drift (AC: version ==
# tag). Read the plist once here rather than re-spawning PlistBuddy per use.
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null) \
    || die "CFBundleShortVersionString missing from $info_plist"
release_tag="v$release_version"
dmg_file="$release_dir/DeskLayouter-$release_version.dmg"

# Sparkle update-archive + appcast paths (derived from the version, like the
# .dmg). The appcast is generated over a staging directory that holds only the
# update zip, so generate_appcast never mistakes the .dmg for an update archive;
# it writes appcast.xml into that same directory.
appcast_dir="$release_dir/appcast"
zip_file="$appcast_dir/DeskLayouter-$release_version.zip"
appcast_file="$appcast_dir/appcast.xml"

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

# Resolve Sparkle's generate_appcast, vendored by SPM under the Sparkle artifact
# bundle. It only exists after a build has fetched Sparkle, so fail loudly with
# a fix rather than letting a later invocation die cryptically.
resolve_generate_appcast() {
    local gen="$sparkle_bin_dir/generate_appcast"
    [[ -x "$gen" ]] || die "generate_appcast not found at $gen; run a build first (e.g. 'make build') so SPM fetches Sparkle"
    print "$gen"
}

# Assert an appcast is well-formed and that its NEWEST <enclosure> (the first
# one; generate_appcast orders newest-first) carries a non-empty
# sparkle:edSignature and a download URL under the GitHub Releases prefix. This
# is the observable proof that EdDSA signing actually happened — used both for
# the local appcast stage and against the downloaded live feed in verify.
assert_appcast_signed() {
    local file="$1"
    xmllint --noout "$file" 2>/dev/null || die "appcast is not well-formed XML: $file"
    local enclosure
    enclosure=$(grep -o '<enclosure[^>]*>' "$file" | head -n1)
    [[ -n "$enclosure" ]] || die "appcast has no <enclosure>: $file"
    # A quoted, non-empty capture ([^"]+) is exactly the "signature is present
    # and non-empty" assertion the AC calls for.
    printf '%s' "$enclosure" | grep -qoE 'sparkle:edSignature="[^"]+"' \
        || die "newest appcast enclosure has no non-empty sparkle:edSignature: $file"
    local url
    url=$(printf '%s' "$enclosure" | grep -oE 'url="[^"]+"' | head -n1 | sed -E 's/url="(.*)"/\1/')
    case "$url" in
        "https://github.com/$release_repo/releases/download/"*) ;;
        *) die "newest appcast enclosure url is not under the GitHub Releases prefix: '${url:-<none>}'" ;;
    esac
    print "$url"
}

# --- changelog / release notes (single source: CHANGELOG.md) --------------

# Print the body of CHANGELOG.md's `## <version> — <date>` section for
# $release_version: every line after that header up to (but not including) the
# next `## ` header, with leading/trailing blank lines trimmed. Prints nothing if
# the section is absent. The version is matched exactly as the first token before
# the ` — ` separator, so `0.1.1` never matches `0.1.10`.
changelog_section() {
    [[ -f "$changelog_file" ]] || return 0
    awk -v ver="$release_version" '
        /^## / {
            hdr = substr($0, 4)
            sep = index(hdr, " — ")
            v = (sep > 0) ? substr(hdr, 1, sep - 1) : hdr
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            inside = (v == ver)
            next
        }
        inside { body = body $0 "\n" }
        END {
            # Trim leading/trailing blank lines.
            gsub(/^\n+/, "", body)
            gsub(/\n+$/, "", body)
            if (length(body) > 0) print body
        }
    ' "$changelog_file"
}

# Assert CHANGELOG.md has a non-empty section for $release_version, or die. This
# is the hard requirement (issue #73): a release cannot be cut without its
# changelog entry, since both the What's-New screen and the GitHub release notes
# derive from it.
require_changelog_entry() {
    [[ -f "$changelog_file" ]] || die "CHANGELOG.md not found at $changelog_file (issue #73: it is the single source of release notes)"
    [[ -n "$(changelog_section)" ]] \
        || die "CHANGELOG.md has no non-empty '## $release_version — <date>' section; add the new version's entry before releasing"
}

# Compose the GitHub release notes for $release_version into $1, deriving the
# highlights from CHANGELOG.md (the single source of release notes).
write_release_notes() {
    local out="$1"
    require_changelog_entry
    {
        print "## Highlights"
        print ""
        changelog_section
    } > "$out"
}

# Print the exact GitHub release notes for $release_version to stdout, without
# building or publishing anything. This is the review artifact: it renders the
# same text do_publish feeds to `gh release create`, so what you approve is what
# ships. Refuses (via require_changelog_entry) if the changelog entry is missing.
do_notes() {
    write_release_notes /dev/stdout
}

# --- preflight ------------------------------------------------------------

do_preflight() {
    local missing=()

    local tool
    for tool in swift codesign xcrun create-dmg gh shasum curl jq xmllint ditto; do
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

    # The release notes derive from CHANGELOG.md (issue #73); catch a missing
    # entry here, at preflight, rather than only at the irreversible publish stage.
    if [[ ! -f "$changelog_file" ]]; then
        missing+=("notes: CHANGELOG.md not found at $changelog_file")
    elif [[ -z "$(changelog_section)" ]]; then
        missing+=("notes: CHANGELOG.md has no '## $release_version — <date>' entry (add it before releasing)")
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
    # Also staple the .app itself. The notary submission notarized the app's code
    # (it rode inside the .dmg), but the .dmg's stapled ticket does NOT travel
    # with the app once Sparkle extracts it from the update zip. Stapling the app
    # gives the zipped bundle its own offline-valid ticket. do_appcast zips this
    # stapled app, so the update archive matches what notarization approved.
    local app
    app=$(manifest_field app)
    [[ -d "$app" ]] || die "no .app at $app; run 'build'/'sign' first"
    xcrun stapler staple "$app" || die "stapling the .app failed"
    # Stapling rewrites the .dmg in place, so the checksum recorded at package
    # time is now stale. Refresh the manifest to the bytes we actually publish,
    # or verify-available would compare the downloaded (stapled) .dmg against a
    # pre-staple hash and always fail.
    write_manifest "$dmg"
    print "release: stapled OK (.dmg + .app)"
}

# --- appcast (zip + EdDSA-signed feed) ------------------------------------

do_appcast() {
    local app
    app=$(manifest_field app)
    [[ -d "$app" ]] || die "no .app to archive at $app; run build/sign/package/staple first"
    local gen
    gen=$(resolve_generate_appcast) || exit 1

    # Fresh staging dir holding ONLY the update zip, so generate_appcast has a
    # single unambiguous archive to sign and never picks up the .dmg.
    rm -rf "$appcast_dir"
    mkdir -p "$appcast_dir"

    print "release: creating Sparkle update zip via ditto (keepParent preserves bundle metadata)..."
    # ditto -c -k --keepParent produces the zip-of-.app layout Sparkle expects,
    # preserving symlinks and extended attributes (unlike `zip`).
    ditto -c -k --keepParent "$app" "$zip_file"
    [[ -f "$zip_file" ]] || die "ditto did not produce $zip_file"

    # Preserve prior appcast state: seed the staging dir with the currently
    # published feed (if any) so generate_appcast keeps older <item> entries
    # instead of emitting a feed with only this release. On the first release
    # the feed 404s and we generate a fresh appcast.
    local feed_code
    feed_code=$(curl -sL -o "$appcast_file" -w '%{http_code}' "$feed_url" 2>/dev/null || echo 000)
    if [[ "$feed_code" == "200" ]]; then
        print "release: seeded prior appcast from $feed_url"
    else
        rm -f "$appcast_file"
        print "release: no prior appcast at $feed_url ($feed_code); generating a fresh feed"
    fi

    print "release: generating EdDSA-signed appcast.xml (private key read from the login keychain)..."
    # --download-url-prefix rewrites the new enclosure's URL to the GitHub
    # Release asset it will be uploaded to; older seeded items keep their own
    # already-absolute URLs. The EdDSA key is read from the keychain automatically.
    "$gen" \
        --download-url-prefix "https://github.com/$release_repo/releases/download/$release_tag/" \
        "$appcast_dir" \
        || die "generate_appcast failed"
    [[ -f "$appcast_file" ]] || die "generate_appcast did not produce $appcast_file"

    local url
    # assert_appcast_signed die()s (in this subshell) on any failure; propagate it.
    url=$(assert_appcast_signed "$appcast_file") || exit 1
    print "release: appcast OK -> $appcast_file"
    print "  newest enclosure: $url"
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
    [[ -f "$zip_file" ]] || die "no update .zip to publish at $zip_file; run 'appcast' first"
    [[ -f "$appcast_file" ]] || die "no appcast to publish at $appcast_file; run 'appcast' first"

    # Derive the release notes from CHANGELOG.md's entry for this version (issue
    # #73). write_release_notes hard-requires that entry, so a release cannot be
    # cut without it — the same section the What's-New screen shows.
    local notes_file="$release_dir/release-notes.md"
    mkdir -p "$release_dir"
    write_release_notes "$notes_file"

    # Upload BOTH the human .dmg and the Sparkle update .zip. The appcast
    # enclosure points at the .zip via the GitHub Releases download URL, so it
    # must be an asset on this same release/tag.
    print "release: creating GitHub Release $tag on $release_repo (assets: .dmg + update .zip)..."
    GH_HOST=github.com gh release create "$tag" "$dmg" "$zip_file" \
        --repo "$release_repo" \
        --title "Desk Layouter $version" \
        --notes-file "$notes_file" \
        --latest \
        || die "gh release create failed"
    print "release: published $tag"

    deploy_appcast_to_pages "$appcast_file"
}

# Deploy appcast.xml to GitHub Pages so it is reachable at SUFeedURL. The deploy
# is transactional and NEVER touches main: it runs entirely inside a throwaway
# clone checked out on the gh-pages branch, overwrites only appcast.xml (leaving
# any other served files such as a CNAME intact), commits, and pushes once. On
# the very first release gh-pages does not exist yet, so we create it as an
# orphan branch. Idempotent: if appcast.xml is byte-identical, nothing is pushed.
deploy_appcast_to_pages() {
    local appcast="$1"
    [[ -f "$appcast" ]] || die "no appcast at $appcast; run 'appcast' first"

    print "release: deploying appcast.xml to GitHub Pages (gh-pages branch on $release_repo)..."
    local tmp work
    tmp=$(mktemp -d)
    work="$tmp/pages"

    if GH_HOST=github.com gh repo clone "$release_repo" "$work" -- \
            --branch gh-pages --single-branch --depth 1 >/dev/null 2>&1; then
        print "  updating existing gh-pages branch"
    else
        print "  gh-pages branch not found; creating it as an orphan branch"
        GH_HOST=github.com gh repo clone "$release_repo" "$work" -- --depth 1 >/dev/null 2>&1 \
            || { rm -rf "$tmp"; die "could not clone $release_repo for the Pages deploy"; }
        git -C "$work" checkout --orphan gh-pages >/dev/null 2>&1 \
            || { rm -rf "$tmp"; die "could not create an orphan gh-pages branch"; }
        git -C "$work" rm -rf . >/dev/null 2>&1 || true
    fi

    cp "$appcast" "$work/appcast.xml"
    git -C "$work" add appcast.xml
    if git -C "$work" diff --cached --quiet; then
        print "  appcast.xml unchanged; nothing to deploy"
        rm -rf "$tmp"
        return 0
    fi
    git -C "$work" \
        -c user.name="Desk Layouter Release" \
        -c user.email="release@desklayouter.local" \
        commit -q -m "Publish appcast for $release_tag" \
        || { rm -rf "$tmp"; die "could not commit appcast to gh-pages"; }
    git -C "$work" push origin gh-pages >/dev/null 2>&1 \
        || { rm -rf "$tmp"; die "could not push gh-pages (Pages deploy)"; }
    rm -rf "$tmp"
    print "  pushed appcast.xml to gh-pages -> reachable at $feed_url"
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
    urls=$(gh release view "$tag" --repo "$repo" --json assets -q '.assets[].url' 2>/dev/null) \
        || die "could not read assets for release $tag on $repo"
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

    # Appcast availability: the feed at SUFeedURL must be live, parse as XML,
    # carry a signed newest enclosure, and that enclosure must be downloadable.
    # This is what an installed build actually polls, so assert against it.
    print "verify-available: appcast at $feed_url must be published, signed, and downloadable..."
    local atmp acode
    atmp=$(mktemp -d)
    acode=$(curl -sL -o "$atmp/appcast.xml" -w '%{http_code}' "$feed_url" 2>/dev/null || echo 000)
    if [[ "$acode" != "200" ]]; then
        print -u2 "  FAIL ($acode)  $feed_url"
        failed=1
    else
        print "  200 OK  $feed_url"
        # assert_appcast_signed die()s on any failure; run it in a subshell so a
        # bad feed fails this stage rather than aborting the whole script, and so
        # verify-local (already run) still reported.
        local enc_url
        if enc_url=$(assert_appcast_signed "$atmp/appcast.xml" 2>/dev/null); then
            print "  appcast XML valid, newest enclosure signed: $enc_url"
            code=$(curl -sIL -o /dev/null -w '%{http_code}' "$enc_url" || echo 000)
            if [[ "$code" == "200" ]]; then
                print "  200 OK  $enc_url"
            else
                print -u2 "  FAIL ($code)  $enc_url"
                failed=1
            fi
        else
            print -u2 "  FAIL: appcast is not valid XML or its newest enclosure lacks a signed download URL"
            failed=1
        fi
    fi
    rm -rf "$atmp"

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
    do_appcast
    if [[ "${RELEASE_PUBLISH:-0}" == "1" ]]; then
        do_publish
        do_verify
    else
        print "release: RELEASE_PUBLISH != 1 — built, signed, notarized, stapled, and appcast-signed locally but NOT published."
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
    appcast) do_appcast ;;
    publish) do_publish ;;
    notes) do_notes ;;
    verify) do_verify ;;
    verify-local) do_verify_local ;;
    verify-available) do_verify_available ;;
    all) do_all ;;
    *) usage ;;
esac
