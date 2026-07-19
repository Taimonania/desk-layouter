#!/bin/zsh

set -eu

# Transactional real-system harness for issue #7.
#
# It exercises the production adapter across multiple managed Assignments and a
# full add → change → remove sequence, verifying PHYSICAL placement (not merely
# plist read-back) with disposable probe apps launched from another Desktop. It
# pre-seeds an UNMANAGED binding and asserts it survives untouched throughout,
# then restores every piece of system state it changed (app-bindings, session
# bindings, active Desktop, processes, temp files) on success or failure.
#
# It restarts the Dock and switches Desktops — the established, transactional
# mechanism from #3 — but never logs out or reboots (that is #8).

probe_name="DeskLayouterDesktopPlacementProbe"
probe_tmp_base="${TMPDIR:-/tmp}"
probe_tmp_base="${probe_tmp_base%/}"
probe_root="$(mktemp -d "$probe_tmp_base/desk-layouter-desktop-probe.XXXXXX")"
probe_binary="$probe_root/$probe_name"

probe_bundle_id_a="com.taimonania.$probe_name.a.$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
probe_bundle_id_b="com.taimonania.$probe_name.b.$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
# The adapter normalizes bundle IDs to lowercase before writing, so persistent
# assertions compare against the lowercased keys.
probe_key_a="${probe_bundle_id_a:l}"
probe_key_b="${probe_bundle_id_b:l}"
# A pre-existing, user-made assignment we do NOT manage. It must never change.
unmanaged_key="com.taimonania.unmanaged.$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr 'A-Z' 'a-z')"

probe_app_a="$probe_root/${probe_name}A.app"
probe_app_b="$probe_root/${probe_name}B.app"
probe_executable_a="$probe_app_a/Contents/MacOS/$probe_name"
probe_executable_b="$probe_app_b/Contents/MacOS/$probe_name"

store_snapshot="$probe_root/com.apple.spaces.plist"
store_snapshot_json="$probe_root/com.apple.spaces.json"
original_bindings="$probe_root/original-app-bindings.json"
original_bindings_present=0
cleanup_started=0
post_dock_delay="${DESKTOP_PROBE_DOCK_DELAY:-2}"
session_bindings_applied=0
original_active_space_id=""
desktop_managed_space_ids="[]"

restore_bindings() {
    /usr/bin/defaults delete com.apple.spaces app-bindings >/dev/null 2>&1 || true
    if (( original_bindings_present == 1 )); then
        while IFS= read -r entry; do
            key="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.key')"
            value="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.value')"
            /usr/bin/defaults write com.apple.spaces app-bindings -dict-add "$key" "$value"
        done < <(/usr/bin/jq -r 'to_entries[] | @base64' "$original_bindings")
    fi
}

# Drives the active Desktop toward the given managed Space ID by pressing
# Control-Left/Right, using the ordered Desktop list to decide direction.
goto_space() {
    local target="$1"
    [[ -x "$probe_executable_a" ]] || return 1
    local current current_index target_index arrow_key
    for _ in {1..24}; do
        current="$($probe_executable_a --active-space 2>/dev/null || true)"
        [[ -n "$current" ]] || return 1
        [[ "$current" == "$target" ]] && return 0
        current_index="$(printf '%s' "$desktop_managed_space_ids" \
            | /usr/bin/jq -r --argjson id "$current" 'index($id) // -1')"
        target_index="$(printf '%s' "$desktop_managed_space_ids" \
            | /usr/bin/jq -r --argjson id "$target" 'index($id) // -1')"
        if (( current_index < 0 || target_index < 0 )); then
            return 1
        fi
        if (( current_index > target_index )); then
            arrow_key=123
        else
            arrow_key=124
        fi
        /usr/bin/osascript -e \
            "tell application \"System Events\" to key code $arrow_key using control down" \
            >/dev/null
        /bin/sleep 0.5
    done
    return 1
}

restore_active_space() {
    [[ -n "$original_active_space_id" ]] || return
    goto_space "$original_active_space_id" || return 1
    # Confirm it settles.
    local stable=0 current
    for _ in {1..12}; do
        current="$($probe_executable_a --active-space 2>/dev/null || true)"
        if [[ "$current" == "$original_active_space_id" ]]; then
            (( stable += 1 ))
            (( stable >= 3 )) && return 0
        else
            stable=0
        fi
        /bin/sleep 0.5
    done
    return 1
}

cleanup() {
    exit_code=$?
    trap - EXIT INT TERM HUP
    if (( cleanup_started == 0 )); then
        cleanup_started=1
        /usr/bin/pkill -f "$probe_name" >/dev/null 2>&1 || true
        restore_bindings
        if (( session_bindings_applied == 1 )); then
            "$probe_executable_a" --set-session-bindings "$original_bindings" || exit_code=1
        fi
        /usr/bin/killall Dock >/dev/null 2>&1 || true
        for _ in {1..30}; do
            /usr/bin/pkill -f "$probe_name" >/dev/null 2>&1 || true
            /bin/sleep 0.1
        done
        restore_active_space || exit_code=1
        case "$probe_root" in
            "$probe_tmp_base"/desk-layouter-desktop-probe.*)
                /bin/rm -rf -- "$probe_root"
                ;;
            *)
                print -u2 "Refusing to remove unexpected probe directory: $probe_root"
                exit_code=1
                ;;
        esac
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

# --- Snapshot the store and the original (unmanaged) bindings ---------------
/usr/bin/defaults export com.apple.spaces "$store_snapshot" >/dev/null
/usr/bin/plutil -convert json -o "$store_snapshot_json" "$store_snapshot"
if /usr/bin/jq -e 'has("app-bindings")' "$store_snapshot_json" >/dev/null; then
    original_bindings_present=1
    /usr/bin/jq '."app-bindings"' "$store_snapshot_json" > "$original_bindings"
else
    /usr/bin/jq -n '{}' > "$original_bindings"
fi

# --- Build one probe binary and two disposable app bundles ------------------
/usr/bin/swiftc \
    -framework AppKit \
    -framework CoreGraphics \
    "${0:A:h}/desktop-placement-probe.swift" \
    -o "$probe_binary"

make_probe_app() {
    local app="$1" bundle_id="$2"
    mkdir -p "$app/Contents/MacOS"
    /bin/cp "$probe_binary" "$app/Contents/MacOS/$probe_name"
    /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleExecutable string $probe_name" \
        -c "Add :CFBundleIdentifier string $bundle_id" \
        -c "Add :CFBundleName string $probe_name" \
        -c 'Add :CFBundlePackageType string APPL' \
        -c 'Add :CFBundleVersion string 1' \
        "$app/Contents/Info.plist"
}
make_probe_app "$probe_app_a" "$probe_bundle_id_a"
make_probe_app "$probe_app_b" "$probe_bundle_id_b"

# --- Determine current Desktop and two non-current target Desktops ----------
original_active_space_id="$($probe_executable_a --active-space)"
built_in_display_identifier="$($probe_executable_a --built-in-display-identifier)"
desktop_managed_space_ids="$(/usr/bin/jq -c --arg display "$built_in_display_identifier" '
    [.SpacesDisplayConfiguration["Management Data"].Monitors[]
    | select(."Display Identifier" == $display)
    | .Spaces[]
    | select(has("TileLayoutManager") | not)
    | .ManagedSpaceID]
' "$store_snapshot_json")"

targets="$(/usr/bin/jq -r \
    --arg display "$built_in_display_identifier" \
    --argjson current "$original_active_space_id" '
    [.SpacesDisplayConfiguration["Management Data"].Monitors[]
    | select(."Display Identifier" == $display)
    | .Spaces[]
    | select(has("TileLayoutManager") | not)
    | select(.ManagedSpaceID != $current and .uuid != "")
    | [.ManagedSpaceID, .uuid]]
' "$store_snapshot_json" | /usr/bin/jq -c '.[0:2]')"

target_count="$(printf '%s' "$targets" | /usr/bin/jq 'length')"
if (( target_count < 2 )); then
    print -u2 "SKIP: this test needs at least two non-current Desktops (with UUIDs) on the built-in display; found $target_count"
    exit 2
fi
target1_id="$(printf '%s' "$targets" | /usr/bin/jq -r '.[0][0]')"
target1_uuid="$(printf '%s' "$targets" | /usr/bin/jq -r '.[0][1]')"
target2_id="$(printf '%s' "$targets" | /usr/bin/jq -r '.[1][0]')"
target2_uuid="$(printf '%s' "$targets" | /usr/bin/jq -r '.[1][1]')"

# The unmanaged binding points at a real Desktop UUID so it is well-formed; it
# names no installed app, so it changes nothing but our preservation assertion.
unmanaged_uuid="$target1_uuid"

print "current-managed-space-id=$original_active_space_id"
print "target1: managed-space-id=$target1_id uuid=$target1_uuid"
print "target2: managed-space-id=$target2_id uuid=$target2_uuid"
print "unmanaged-key=$unmanaged_key"

# --- Helpers ----------------------------------------------------------------
persistent_bindings_json() {
    /usr/bin/defaults export com.apple.spaces - 2>/dev/null \
        | /usr/bin/plutil -convert json -o - - 2>/dev/null \
        | /usr/bin/jq -c '.["app-bindings"] // {}'
}

assert_persistent_value() {
    local label="$1" key="$2" expected="$3" got
    got="$(persistent_bindings_json | /usr/bin/jq -r --arg k "$key" '.[$k] // ""')"
    if [[ "$got" == "$expected" ]]; then
        print "PASS: $label"
    else
        print -u2 "FAIL: $label — expected $key=$expected, got '$got'"
        exit 1
    fi
}

assert_persistent_absent() {
    local label="$1" key="$2" present
    present="$(persistent_bindings_json | /usr/bin/jq -r --arg k "$key" 'has($k)')"
    if [[ "$present" == "false" ]]; then
        print "PASS: $label"
    else
        print -u2 "FAIL: $label — expected key $key to be absent"
        exit 1
    fi
}

run_apply() {
    swift run DeskLayouterDesktopPlacementTests "$1" "$2"
    /bin/sleep "$post_dock_delay"
}

observe_probe() {
    local app="$1" exe="$2" tag="$3"
    local winfile="$probe_root/window-$tag"
    /bin/rm -f "$winfile"
    /usr/bin/open -n "$app" --args --window-number-file "$winfile"
    local pid=""
    for _ in {1..350}; do
        pid="$(/usr/bin/pgrep -f "$exe" | head -n 1 || true)"
        [[ -n "$pid" ]] && break
        /bin/sleep 0.1
    done
    [[ -n "$pid" ]] || { print -u2 "FAIL: probe $tag did not launch"; exit 1; }
    for _ in {1..100}; do [[ -s "$winfile" ]] && break; /bin/sleep 0.1; done
    [[ -s "$winfile" ]] || { print -u2 "FAIL: probe $tag did not report its window"; exit 1; }
    local win; win="$(<"$winfile")"
    local obs=""
    for _ in {1..40}; do
        obs="$($exe --inspect "$pid" "$win" 2>/dev/null || true)"
        [[ -n "$obs" ]] && break
        /bin/sleep 0.1
    done
    [[ -n "$obs" ]] || { print -u2 "FAIL: probe $tag produced no inspectable window"; exit 1; }
    printf '%s' "$obs" | /usr/bin/jq -c '[.[].managedSpaceIDs[]] | unique | sort'
}

quit_probe() {
    /usr/bin/pkill -f "$1" >/dev/null 2>&1 || true
    for _ in {1..30}; do /usr/bin/pgrep -f "$1" >/dev/null 2>&1 || break; /bin/sleep 0.1; done
}

assert_only() {
    local label="$1" observed="$2" expected="$3"
    if [[ "$observed" == "[$expected]" ]]; then
        print "PASS: $label (managed space $expected)"
    else
        print -u2 "FAIL: $label — expected [$expected], observed $observed"
        exit 1
    fi
}

# --- Pre-seed the unmanaged binding -----------------------------------------
/usr/bin/defaults write com.apple.spaces app-bindings -dict-add "$unmanaged_key" "$unmanaged_uuid"
session_bindings_applied=1

# --- Step 1: apply multiple managed Assignments at once ---------------------
print "=== step 1: apply two managed Assignments (A→target1, B→target2) ==="
bindings_step1="$(/usr/bin/jq -n \
    --arg a "$probe_bundle_id_a" --arg av "$target1_uuid" \
    --arg b "$probe_bundle_id_b" --arg bv "$target2_uuid" \
    '{($a): $av, ($b): $bv}')"
owned_ab="$(/usr/bin/jq -n --arg a "$probe_bundle_id_a" --arg b "$probe_bundle_id_b" '[$a, $b]')"
run_apply "$bindings_step1" "$owned_ab"

observed_a="$(observe_probe "$probe_app_a" "$probe_executable_a" a1)"
assert_only "A lands on its Desktop" "$observed_a" "$target1_id"
quit_probe "$probe_executable_a"

observed_b="$(observe_probe "$probe_app_b" "$probe_executable_b" b1)"
assert_only "B lands on its Desktop" "$observed_b" "$target2_id"
quit_probe "$probe_executable_b"

assert_persistent_value "A persisted to target1" "$probe_key_a" "$target1_uuid"
assert_persistent_value "B persisted to target2" "$probe_key_b" "$target2_uuid"
assert_persistent_value "unmanaged binding preserved after step 1" "$unmanaged_key" "$unmanaged_uuid"

# --- Step 2: change A to a different Desktop --------------------------------
print "=== step 2: change A from target1 to target2 ==="
bindings_step2="$(/usr/bin/jq -n \
    --arg a "$probe_bundle_id_a" --arg av "$target2_uuid" \
    --arg b "$probe_bundle_id_b" --arg bv "$target2_uuid" \
    '{($a): $av, ($b): $bv}')"
run_apply "$bindings_step2" "$owned_ab"

observed_a="$(observe_probe "$probe_app_a" "$probe_executable_a" a2)"
assert_only "A moved to its new Desktop" "$observed_a" "$target2_id"
quit_probe "$probe_executable_a"

assert_persistent_value "A re-persisted to target2" "$probe_key_a" "$target2_uuid"
assert_persistent_value "unmanaged binding preserved after step 2" "$unmanaged_key" "$unmanaged_uuid"

# --- Step 3: remove A; B stays; unmanaged survives -------------------------
print "=== step 3: remove A (B remains) ==="
# A is removed but still OWNED on this Apply (mirrors the app's
# ownedBundleIdentifiers = managed ∪ pendingRemovals) so its key is deleted.
bindings_step3="$(/usr/bin/jq -n --arg b "$probe_bundle_id_b" --arg bv "$target2_uuid" '{($b): $bv}')"
owned_step3="$owned_ab"
run_apply "$bindings_step3" "$owned_step3"

assert_persistent_absent "A's key removed from persistent bindings" "$probe_key_a"
assert_persistent_value "B still persisted to target2" "$probe_key_b" "$target2_uuid"
assert_persistent_value "unmanaged binding preserved after step 3" "$unmanaged_key" "$unmanaged_uuid"

# Physical proof the removal also took effect in the live session: launched from
# the original current Desktop, A must now open there (not on its old target).
if ! goto_space "$original_active_space_id"; then
    print -u2 "FAIL: could not return to the original Desktop to verify session removal"
    exit 1
fi
observed_a="$(observe_probe "$probe_app_a" "$probe_executable_a" a3)"
assert_only "A returns to the current Desktop after removal (session binding gone)" \
    "$observed_a" "$original_active_space_id"
quit_probe "$probe_executable_a"

observed_b="$(observe_probe "$probe_app_b" "$probe_executable_b" b3)"
assert_only "B still lands on its Desktop after A's removal" "$observed_b" "$target2_id"
quit_probe "$probe_executable_b"

print "PASS: multi-assignment add, change, and removal verified across persistent and live session; unmanaged binding preserved and system state restored"
