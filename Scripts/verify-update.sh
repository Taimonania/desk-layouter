#!/bin/zsh
set -eu

# Human-gated, run-once mechanism-validation harness for issue #47.
#
# Proves the linchpin claim behind Developer ID signing: a STABLE code-signing
# identity keeps the Accessibility (TCC) grant alive across a Sparkle
# auto-update, so Arrange keeps working without re-authorization.
#
# This is NOT a per-release gate and NOT part of `make test`/CI. It validates
# the signing + update MECHANISM and is re-run only when that mechanism changes:
#   * Developer ID certificate / identity rotation,
#   * bundle-id or designated-requirement change,
#   * a major Sparkle upgrade,
#   * an OS TCC-behavior change.
#
# Verifying that a grant survives an update requires a boundary the process
# cannot span in a single run: the operator grants Accessibility and lets
# Sparkle install N+1 BETWEEN `arm` and `verify`. All state therefore lives in a
# persistent directory under $HOME, mirroring verify-session-boundary.sh.
#
# Subcommands:
#   arm      Build a SIGNED version N and install it to an ISOLATED test dir
#            (never /Applications; a dir under $HOME so TCC treats it as a real
#            app). Record N's designated requirement. Build a SIGNED version N+1
#            (higher version, SAME bundle id + SAME identity => stable DR), zip
#            it, and produce a local EdDSA-signed appcast served over a loopback
#            http.server. Persists state and PRINTS the human-gated next steps.
#            Does NOTHING irreversible outside the isolated test dir/state.
#   verify   Assert the installed app is now N+1 (Info.plist version), assert its
#            designated requirement is UNCHANGED from armed N (the crux — a
#            stable DR is why TCC keeps the grant), and assert Accessibility
#            trust survived. Prints PASS/FAIL with the macOS build, then runs
#            restore.
#   restore  Kill the local server, remove the test app, clear its TCC
#            Accessibility entry, and delete staged appcast/state. Transactional
#            and idempotent; safe to run standalone and safe to run twice.
#
# NOTARIZATION IS OPTIONAL for this harness: signed is the requirement, and
# locally-built bundles carry no quarantine attribute, so Gatekeeper allows them
# without a notarization ticket. The harness therefore does NOT depend on
# notarytool or the network.

self="${0:A}"
repo_dir="${0:A:h:h}"
build_app_script="${0:A:h}/build-app.sh"
info_plist="$repo_dir/App/Info.plist"
sparkle_bin_dir="$repo_dir/.build/artifacts/sparkle/Sparkle/bin"
base_app="$repo_dir/.build/Desk Layouter.app"

test_root="$HOME/Applications/DeskLayouter-VerifyUpdate"
state_dir="$test_root/state"
installed_app="$test_root/Desk Layouter.app"   # starts as N; Sparkle replaces it with N+1 in place
np1_app="$test_root/DeskLayouter-Np1.app"      # staged N+1 bundle, kept for inspection
appcast_dir="$test_root/appcast"
metadata="$state_dir/metadata.json"
sw_vers_file="$state_dir/sw_vers.txt"
server_pid_file="$state_dir/server.pid"
server_log="$state_dir/server.log"

server_port="${UPDATE_VERIFY_PORT:-8721}"

usage() {
    print -u2 "usage: $0 {arm|verify|restore}"
    exit 2
}

die() { print -u2 "verify-update: $1"; exit 1; }

# --- shared helpers -------------------------------------------------------

# Resolve the sole Developer ID Application identity, honoring an explicit
# override, exactly like Scripts/release.sh. A STABLE identity is the whole
# point of this test, so refuse ambiguity rather than guess.
resolve_identity() {
    if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
        print "$DEVELOPER_ID_APPLICATION"
        return 0
    fi
    local found count
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' || true)
    count=$(printf '%s\n' "$found" | grep -c 'Developer ID Application' || true)
    if [[ "$count" -eq 0 ]]; then
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        print -u2 "verify-update: multiple Developer ID Application identities found; set DEVELOPER_ID_APPLICATION to pick one:"
        printf '%s\n' "$found" >&2
        return 2
    fi
    printf '%s\n' "$found" | sed -E 's/.*"(.*)".*/\1/'
}

# The designated requirement is what TCC pins a grant to. For a Developer ID
# bundle it is derived from the bundle id + certificate chain and is INDEPENDENT
# of the version, so N and N+1 must produce byte-identical strings — that
# stability is exactly why the Accessibility grant survives the update.
designated_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true
}

# Increment the last dotted component (0.1.1 -> 0.1.2); append .1 if the tail is
# non-numeric; bump a bare integer directly.
bump_patch() {
    local v="$1"
    if [[ "$v" == *.* ]]; then
        local head="${v%.*}" tail="${v##*.}"
        if [[ "$tail" == <-> ]]; then
            print "$head.$((tail + 1))"
        else
            print "$v.1"
        fi
    elif [[ "$v" == <-> ]]; then
        print "$((v + 1))"
    else
        print "$v.1"
    fi
}

# Stamp a copy of the freshly-built signed base app with a target version + feed
# URL, then RE-SIGN inside-out with the same identity. Editing Info.plist breaks
# only the outer bundle seal; Sparkle's nested helpers were already signed by
# build-app.sh with this same identity and are left untouched, so --verify
# --strict passes. No --timestamp: a secure timestamp needs the network and does
# not affect the designated requirement, and this harness must not depend on it.
stage_version() {
    local dest="$1" short="$2" build="$3" feed="$4" identity="$5"
    /bin/rm -rf "$dest"
    /bin/cp -R "$base_app" "$dest"
    local plist="$dest/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $feed" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed" "$plist"
    /usr/bin/codesign --force --options runtime --sign "$identity" "$dest/Contents/MacOS/DeskLayouter"
    /usr/bin/codesign --force --options runtime --sign "$identity" "$dest"
    /usr/bin/codesign --verify --strict "$dest" \
        || die "re-signing failed --verify --strict: $dest"
}

stop_server() {
    [[ -f "$server_pid_file" ]] || return 0
    local pid
    pid="$(<"$server_pid_file")"
    if [[ -n "$pid" ]] && /bin/kill -0 "$pid" 2>/dev/null; then
        /bin/kill "$pid" 2>/dev/null || true
    fi
    /bin/rm -f "$server_pid_file"
}

# --- restore --------------------------------------------------------------

do_restore() {
    if [[ ! -d "$test_root" ]]; then
        print "restore: no armed state found; nothing to do"
        return 0
    fi

    local bundle_id=""
    if [[ -f "$metadata" ]]; then
        bundle_id="$(/usr/bin/jq -r '.bundle_id // ""' "$metadata")"
    fi

    stop_server
    /usr/bin/pkill -f "$installed_app/Contents/MacOS/DeskLayouter" >/dev/null 2>&1 || true

    # Clear the Accessibility grant for the bundle id. NOTE: this resets the
    # REAL shipping bundle id (com.taimonania.DeskLayouter) — see docs; the
    # operator must have granted the TEST copy (which shares the DR), and a real
    # installed Desk Layouter would need re-granting afterward.
    if [[ -n "$bundle_id" ]]; then
        /usr/bin/tccutil reset Accessibility "$bundle_id" >/dev/null 2>&1 || true
    fi

    case "$test_root" in
        "$HOME/Applications/DeskLayouter-VerifyUpdate")
            /bin/rm -rf -- "$test_root"
            ;;
        *)
            print -u2 "restore: refusing to remove unexpected test directory: $test_root"
            return 1
            ;;
    esac
    print "restore: local server stopped, test app + staged appcast/state removed, TCC Accessibility entry cleared"
    return 0
}

# --- arm ------------------------------------------------------------------

do_arm() {
    if [[ -d "$test_root" ]]; then
        die "test dir already exists ($test_root). Run '$self restore' first."
    fi

    local identity
    identity=$(resolve_identity) \
        || die "no single Developer ID Application identity in the keychain (a stable identity is required for this test)"

    [[ -x "$sparkle_bin_dir/generate_appcast" ]] \
        || die "generate_appcast not found at $sparkle_bin_dir; run 'make build' first so SPM fetches Sparkle"

    mkdir -p "$state_dir" "$appcast_dir"

    # Transactional guard: roll back the isolated test dir if arm fails partway.
    # Cleared only on full success, since a successful arm intentionally leaves
    # the system armed for the human-gated boundary.
    arm_succeeded=0
    trap '(( ${arm_succeeded:-0} )) || do_restore' EXIT INT TERM

    /usr/bin/sw_vers > "$sw_vers_file"

    local bundle_id
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist") \
        || die "CFBundleIdentifier missing from $info_plist"

    local base_short base_build n_short n_build np1_short np1_build
    base_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
    base_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
    n_short="$base_short"
    n_build="$base_build"
    np1_short="$(bump_patch "$base_short")"
    np1_build="$((base_build + 1))"   # Sparkle compares CFBundleVersion; N+1 must be strictly higher

    local feed_url="http://127.0.0.1:$server_port/appcast.xml"

    # 1. Build the base app ONCE, signed with the Developer ID identity (single
    #    arch — fast; the designated requirement does not depend on arch).
    print "arm: building signed base app via build-app.sh (identity '$identity')..."
    DEVELOPER_ID_APPLICATION="$identity" CONFIGURATION=release "$build_app_script" >/dev/null
    [[ -d "$base_app" ]] || die "build-app.sh did not produce $base_app"

    # 2. Stamp N (installed) and N+1 (update target). Same bundle id + identity.
    print "arm: staging version N ($n_short build $n_build) and N+1 ($np1_short build $np1_build)..."
    stage_version "$installed_app" "$n_short" "$n_build" "$feed_url" "$identity"
    stage_version "$np1_app" "$np1_short" "$np1_build" "$feed_url" "$identity"

    # 3. Record + assert the designated requirements match (the crux).
    local n_dr np1_dr
    n_dr="$(designated_requirement "$installed_app")"
    np1_dr="$(designated_requirement "$np1_app")"
    [[ -n "$n_dr" ]] || die "could not read N designated requirement"
    if [[ "$n_dr" != "$np1_dr" ]]; then
        print -u2 "arm: FAIL — designated requirements differ between N and N+1:"
        print -u2 "  N   : $n_dr"
        print -u2 "  N+1 : $np1_dr"
        die "a stable designated requirement is required; check the signing identity/bundle id"
    fi

    # 4. Zip N+1 (Sparkle layout) and generate the local EdDSA-signed appcast.
    local zip_file="$appcast_dir/DeskLayouter-$np1_short.zip"
    print "arm: creating Sparkle update zip + local EdDSA-signed appcast..."
    /usr/bin/ditto -c -k --keepParent "$np1_app" "$zip_file"
    [[ -f "$zip_file" ]] || die "ditto did not produce $zip_file"
    # Keep ONLY the zip in the dir generate_appcast scans (np1_app lives outside
    # appcast_dir), so it has a single unambiguous archive to sign.
    "$sparkle_bin_dir/generate_appcast" \
        --download-url-prefix "http://127.0.0.1:$server_port/" \
        "$appcast_dir" \
        || die "generate_appcast failed"
    [[ -f "$appcast_dir/appcast.xml" ]] || die "generate_appcast did not produce appcast.xml"
    /usr/bin/xmllint --noout "$appcast_dir/appcast.xml" \
        || die "generated appcast is not well-formed XML"
    grep -qoE 'sparkle:edSignature="[^"]+"' "$appcast_dir/appcast.xml" \
        || die "generated appcast enclosure has no non-empty sparkle:edSignature"

    # 5. Serve the appcast over a loopback http.server for the human step.
    local served=0
    if command -v python3 >/dev/null 2>&1; then
        ( cd "$appcast_dir" && exec python3 -m http.server "$server_port" --bind 127.0.0.1 ) \
            >"$server_log" 2>&1 &
        print $! > "$server_pid_file"
        disown 2>/dev/null || true
        served=1
    fi

    # 6. Persist state for verify/restore.
    /usr/bin/jq -n \
        --arg bundle_id "$bundle_id" \
        --arg installed_app "$installed_app" \
        --arg np1_app "$np1_app" \
        --arg n_short "$n_short" \
        --arg n_build "$n_build" \
        --arg np1_short "$np1_short" \
        --arg np1_build "$np1_build" \
        --arg n_dr "$n_dr" \
        --arg np1_dr "$np1_dr" \
        --arg feed_url "$feed_url" \
        --arg identity "$identity" \
        '{bundle_id:$bundle_id, installed_app:$installed_app, np1_app:$np1_app,
          n_short:$n_short, n_build:$n_build, np1_short:$np1_short, np1_build:$np1_build,
          n_dr:$n_dr, np1_dr:$np1_dr, feed_url:$feed_url, identity:$identity}' \
        > "$metadata"

    arm_succeeded=1
    trap - EXIT INT TERM

    print ""
    print "=== ARMED ==="
    print "macOS build:        $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    print "signing identity:   $identity"
    print "bundle id:          $bundle_id"
    print "installed N:        $installed_app  ($n_short build $n_build)"
    print "update target N+1:  $np1_short build $np1_build"
    print "designated req:     $n_dr"
    print "local feed URL:     $feed_url"
    if (( served )); then
        print "appcast server:     python3 -m http.server on 127.0.0.1:$server_port (pid $(<"$server_pid_file"))"
    else
        print "appcast server:     python3 not found — start it yourself:"
        print "                      (cd '$appcast_dir' && python3 -m http.server $server_port --bind 127.0.0.1)"
    fi
    print ""
    print "NEXT (human-gated):"
    print "  1. Open the installed test app:   open '$installed_app'"
    print "  2. Grant it Accessibility in System Settings > Privacy & Security >"
    print "     Accessibility, then confirm Arrange works (moves a window)."
    print "     NOTE: it shares the shipping bundle id + designated requirement, so"
    print "     this grants the '$bundle_id' identity."
    print "  3. In the menu-bar menu choose 'Check for Updates…'. The test app's"
    print "     SUFeedURL points at the local appcast, so Sparkle offers N+1."
    print "     Install it and let the app relaunch."
    print "  4. Run:  $self verify"
    print ""
    print "This script has NOT prompted for or reset any TCC grant. To abandon the"
    print "test without the human boundary, run:  $self restore"
}

# --- verify ---------------------------------------------------------------

check_ax_trust() {
    local bundle_id="$1"
    # Preferred automated signal: the system TCC database. Accessibility lives in
    # the SYSTEM store; reading it needs this terminal to hold Full Disk Access.
    local sys_db="/Library/Application Support/com.apple.TCC/TCC.db"
    local val=""
    if val=$(/usr/bin/sqlite3 "$sys_db" \
        "SELECT auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client='$bundle_id' AND client_type=0 ORDER BY auth_value DESC LIMIT 1;" 2>/dev/null) \
        && [[ -n "$val" ]]; then
        if [[ "$val" == "2" || "$val" == "3" ]]; then
            print "  AX-trust: PASS (system TCC.db shows Accessibility ALLOWED for $bundle_id post-update, auth_value=$val)"
            return 0
        fi
        print -u2 "  AX-trust: FAIL (system TCC.db shows Accessibility NOT allowed for $bundle_id, auth_value=$val)"
        return 1
    fi

    # Fallback: operator confirmation (a shell cannot query another process's
    # AXIsProcessTrusted, and TCC.db is unreadable without Full Disk Access).
    print "  AX-trust: system TCC.db unreadable (this terminal lacks Full Disk Access); falling back to operator confirmation."
    if [[ -r /dev/tty ]]; then
        local ans=""
        print -n "  Did Arrange work after the update WITHOUT any Accessibility re-authorization prompt? [y/N] "
        read -r ans < /dev/tty || ans=""
        case "$ans" in
            y|Y|yes|YES) print "  AX-trust: PASS (operator confirmed: no re-prompt, Arrange worked)"; return 0 ;;
            *) print -u2 "  AX-trust: FAIL (operator did not confirm)"; return 1 ;;
        esac
    fi
    print -u2 "  AX-trust: UNVERIFIED (no TTY for operator confirmation, TCC.db unreadable) — treating as FAIL"
    return 1
}

do_verify() {
    if [[ ! -f "$metadata" ]]; then
        print -u2 "FAIL: no armed state found. Run '$self arm' first."
        exit 1
    fi

    local bundle_id np1_short np1_build n_dr feed_url
    bundle_id="$(/usr/bin/jq -r '.bundle_id' "$metadata")"
    np1_short="$(/usr/bin/jq -r '.np1_short' "$metadata")"
    np1_build="$(/usr/bin/jq -r '.np1_build' "$metadata")"
    n_dr="$(/usr/bin/jq -r '.n_dr' "$metadata")"
    feed_url="$(/usr/bin/jq -r '.feed_url' "$metadata")"

    print "recorded macOS build:"
    /bin/cat "$sw_vers_file"
    print ""

    if [[ ! -d "$installed_app" ]]; then
        print -u2 "FAIL: the installed test app is gone ($installed_app). Re-run '$self arm'."
        do_restore
        exit 1
    fi

    local failed=0

    # 1. Version check (fully automated). If the app is still N, the human step
    #    has not happened yet — fail CLEANLY with guidance, not a set -eu crash.
    local cur_short cur_build
    cur_short="$(plist_value "$installed_app" CFBundleShortVersionString)"
    cur_build="$(plist_value "$installed_app" CFBundleVersion)"
    if [[ "$cur_short" == "$np1_short" && "$cur_build" == "$np1_build" ]]; then
        print "PASS: installed app is N+1 ($cur_short build $cur_build) — Sparkle applied the update"
    else
        print -u2 "FAIL: installed app is $cur_short build $cur_build, expected N+1 $np1_short build $np1_build."
        print -u2 "      The Sparkle update has not been applied yet. Complete the human step:"
        print -u2 "        1) open '$installed_app'  2) grant Accessibility  3) Check for Updates… ($feed_url)"
        print -u2 "      then re-run '$self verify'."
        print ""
        print "RESULT: FAIL on $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
        print ""
        print "cleaning up..."
        do_restore
        exit 1
    fi

    # 2. Designated requirement unchanged (fully automated, the crux).
    /usr/bin/codesign --verify --strict "$installed_app" \
        || { print -u2 "FAIL: updated app fails codesign --verify --strict"; failed=1; }
    local cur_dr
    cur_dr="$(designated_requirement "$installed_app")"
    if [[ "$cur_dr" == "$n_dr" ]]; then
        print "PASS: designated requirement UNCHANGED across N -> N+1 (this is why TCC kept the grant)"
        print "      DR: $cur_dr"
    else
        print -u2 "FAIL: designated requirement changed across the update:"
        print -u2 "  armed N : $n_dr"
        print -u2 "  updated : $cur_dr"
        failed=1
    fi

    # 3. Accessibility trust survived (automated signal, operator fallback).
    check_ax_trust "$bundle_id" || failed=1

    print ""
    if (( failed == 0 )); then
        print "RESULT: PASS on $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    else
        print "RESULT: FAIL on $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    fi

    print ""
    print "cleaning up..."
    do_restore
    return "$failed"
}

# --- dispatch -------------------------------------------------------------

(( $# == 1 )) || usage
case "$1" in
    arm) do_arm ;;
    verify) do_verify ;;
    restore) do_restore ;;
    *) usage ;;
esac
