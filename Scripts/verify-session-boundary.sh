#!/bin/zsh
set -eu

# Two-phase session-boundary compatibility harness for issue #8.
#
# Verifying logout/login and reboot rehydration requires a boundary the process
# cannot span in a single run: the logout or reboot happens BETWEEN `arm` and
# `verify`. All state therefore lives in a PERSISTENT directory under $HOME that
# survives a reboot (a reboot clears /tmp and $TMPDIR, so nothing is staged
# there).
#
# Subcommands:
#   arm      Snapshot state, build a disposable probe app into the persistent
#            dir, and Apply an Assignment for it to a non-active Desktop on the
#            active display THROUGH THE PRODUCTION ADAPTER. Records the macOS build and
#            prints the human instructions. NEVER logs out or reboots.
#   verify   Launch the probe from the current (different) Desktop WITHOUT Desk
#            Layouter running and assert ACTUAL window placement on the assigned
#            Desktop. Prints PASS/FAIL and the recorded macOS build, then runs
#            restore.
#   restore  Restore the original app-bindings, live session bindings, and active
#            Desktop, remove the probe, and delete the persistent state dir.
#            Transactional and idempotent; safe to run standalone.
#
# This harness NEVER logs out, reboots, shuts down, or ends the session.

self="${0:A}"
repo_dir="${0:A:h:h}"
probe_source="${0:A:h}/desktop-placement-probe.swift"
probe_name="DeskLayouterSessionProbe"
state_dir="$HOME/Library/Application Support/DeskLayouter/session-boundary-test"
probe_dir="$state_dir/probe"
probe_app="$probe_dir/${probe_name}.app"
probe_executable="$probe_app/Contents/MacOS/$probe_name"
probe_binary="$probe_dir/$probe_name"
metadata="$state_dir/metadata.json"
original_bindings="$state_dir/original-app-bindings.json"
store_snapshot="$state_dir/com.apple.spaces.plist"
store_snapshot_json="$state_dir/com.apple.spaces.json"
sw_vers_file="$state_dir/sw_vers.txt"
post_dock_delay="${SESSION_BOUNDARY_DOCK_DELAY:-2}"

usage() {
    print -u2 "usage: $0 {arm|verify|restore}"
    exit 2
}

# --- shared helpers -------------------------------------------------------

persistent_bindings_json() {
    /usr/bin/defaults export com.apple.spaces - 2>/dev/null \
        | /usr/bin/plutil -convert json -o - - 2>/dev/null \
        | /usr/bin/jq -c '.["app-bindings"] // {}'
}

current_store_json() {
    local tmp_plist tmp_json
    tmp_plist="$(/usr/bin/mktemp)"
    tmp_json="$(/usr/bin/mktemp)"
    /usr/bin/defaults export com.apple.spaces "$tmp_plist" >/dev/null
    /usr/bin/plutil -convert json -o "$tmp_json" "$tmp_plist"
    /bin/cat "$tmp_json"
    /bin/rm -f "$tmp_plist" "$tmp_json"
}

# Managed space IDs for the active display in the CURRENT store. Recomputed on
# demand because macOS may re-mint these integers across a session boundary; the
# Desktop UUID is the stable identifier.
current_desktop_managed_space_ids() {
    local display="$1"
    current_store_json | /usr/bin/jq -c --arg display "$display" '
        [.SpacesDisplayConfiguration["Management Data"].Monitors[]
        | select(."Display Identifier" == $display)
        | .Spaces[]
        | select(has("TileLayoutManager") | not)
        | .ManagedSpaceID]
    '
}

# Current managed space ID for a Desktop identified by its stable UUID.
managed_space_id_for_uuid() {
    local display="$1" uuid="$2"
    current_store_json | /usr/bin/jq -r --arg display "$display" --arg uuid "$uuid" '
        [.SpacesDisplayConfiguration["Management Data"].Monitors[]
        | select(."Display Identifier" == $display)
        | .Spaces[]
        | select(.uuid == $uuid)
        | .ManagedSpaceID][0] // empty
    '
}

restore_bindings_from_original() {
    # Return com.apple.spaces app-bindings to exactly what it was before `arm`.
    # If the original had no app-bindings key, the key is left absent.
    /usr/bin/defaults delete com.apple.spaces app-bindings >/dev/null 2>&1 || true
    [[ -f "$original_bindings" ]] || return 0
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        local key value
        key="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.key')"
        value="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.value')"
        /usr/bin/defaults write com.apple.spaces app-bindings -dict-add "$key" "$value"
    done < <(/usr/bin/jq -r 'to_entries[] | @base64' "$original_bindings")
}

goto_space() {
    # Best-effort navigation to a target managed space ID using the same
    # arrow-key approach as verify-desktop-placement.sh. Skips gracefully if the
    # target ID is not present on the current active display (e.g. IDs re-minted
    # after a reboot), so restore stays safe.
    local target="$1" display="$2"
    [[ -n "$target" ]] || return 0
    [[ -x "$probe_executable" ]] || return 0
    local ids current current_index target_index arrow_key
    ids="$(current_desktop_managed_space_ids "$display")"
    target_index="$(printf '%s' "$ids" | /usr/bin/jq -r --argjson id "$target" 'index($id) // -1')"
    (( target_index >= 0 )) || return 0
    for _ in {1..24}; do
        current="$("$probe_executable" --active-space 2>/dev/null || true)"
        [[ -n "$current" ]] || return 0
        [[ "$current" == "$target" ]] && return 0
        current_index="$(printf '%s' "$ids" | /usr/bin/jq -r --argjson id "$current" 'index($id) // -1')"
        (( current_index >= 0 )) || return 0
        if (( current_index > target_index )); then
            arrow_key=123
        else
            arrow_key=124
        fi
        /usr/bin/osascript -e \
            "tell application \"System Events\" to key code $arrow_key using control down" \
            >/dev/null 2>&1 || return 0
        /bin/sleep 0.5
    done
    return 0
}

make_probe_app() {
    local bundle_id="$1"
    mkdir -p "$probe_app/Contents/MacOS"
    /bin/cp "$probe_binary" "$probe_executable"
    /usr/bin/plutil -create xml1 "$probe_app/Contents/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Add :CFBundleExecutable string $probe_name" \
        -c "Add :CFBundleIdentifier string $bundle_id" \
        -c "Add :CFBundleName string $probe_name" \
        -c 'Add :CFBundlePackageType string APPL' \
        -c 'Add :CFBundleVersion string 1' \
        "$probe_app/Contents/Info.plist"
}

# --- restore --------------------------------------------------------------

do_restore() {
    if [[ ! -d "$state_dir" ]]; then
        print "restore: no armed state found; nothing to do"
        return 0
    fi

    local display="" active_id="" active_uuid=""
    if [[ -f "$metadata" ]]; then
        display="$(/usr/bin/jq -r '.active_display_identifier // ""' "$metadata")"
        active_id="$(/usr/bin/jq -r '.original_active_space_id // ""' "$metadata")"
        active_uuid="$(/usr/bin/jq -r '.original_active_uuid // ""' "$metadata")"
    fi

    /usr/bin/pkill -f "$probe_name" >/dev/null 2>&1 || true

    restore_bindings_from_original

    if [[ -x "$probe_executable" && -f "$original_bindings" ]]; then
        "$probe_executable" --set-session-bindings "$original_bindings" || true
    fi

    /usr/bin/killall Dock >/dev/null 2>&1 || true
    for _ in {1..30}; do
        /usr/bin/pkill -f "$probe_name" >/dev/null 2>&1 || true
        /bin/sleep 0.1
    done

    # Return to the original active Desktop. Prefer re-resolving the stable UUID
    # to its CURRENT managed space ID (the recorded integer ID may have been
    # re-minted across a logout/reboot); fall back to the recorded integer for
    # the in-session case where the UUID could not be captured.
    if [[ -n "$display" ]]; then
        local restore_active_id="$active_id"
        if [[ -n "$active_uuid" ]]; then
            local resolved
            resolved="$(managed_space_id_for_uuid "$display" "$active_uuid")"
            [[ -n "$resolved" ]] && restore_active_id="$resolved"
        fi
        if [[ -n "$restore_active_id" ]]; then
            goto_space "$restore_active_id" "$display"
        fi
    fi

    case "$state_dir" in
        "$HOME/Library/Application Support/DeskLayouter/session-boundary-test")
            /bin/rm -rf -- "$state_dir"
            ;;
        *)
            print -u2 "restore: refusing to remove unexpected state directory: $state_dir"
            return 1
            ;;
    esac
    print "restore: original app-bindings, live session bindings, active Desktop, and probe removed; state dir cleaned"
    return 0
}

# --- arm ------------------------------------------------------------------

do_arm() {
    if [[ -d "$state_dir" ]]; then
        print -u2 "arm: state dir already exists ($state_dir). Run restore first."
        exit 1
    fi
    mkdir -p "$probe_dir"

    # Transactional guard: if arm fails at any point (e.g. the seed write or the
    # production Apply), roll the system and staged state back. Cleared only once
    # arm has fully succeeded, since a successful arm intentionally leaves the
    # system armed for the human-gated boundary.
    arm_succeeded=0
    trap '(( ${arm_succeeded:-0} )) || do_restore' EXIT INT TERM

    # 1. True-original snapshot of com.apple.spaces (before we seed anything).
    /usr/bin/defaults export com.apple.spaces "$store_snapshot" >/dev/null
    /usr/bin/plutil -convert json -o "$store_snapshot_json" "$store_snapshot"
    local original_present
    if /usr/bin/jq -e 'has("app-bindings")' "$store_snapshot_json" >/dev/null; then
        original_present=1
        /usr/bin/jq '."app-bindings"' "$store_snapshot_json" > "$original_bindings"
    else
        original_present=0
        /usr/bin/jq -n '{}' > "$original_bindings"
    fi

    # 2. Record the exact macOS build under test.
    /usr/bin/sw_vers > "$sw_vers_file"

    # 3. Build the disposable probe into the persistent dir.
    /usr/bin/swiftc \
        -framework AppKit \
        -framework CoreGraphics \
        "$probe_source" \
        -o "$probe_binary"

    local bundle_id key
    bundle_id="com.taimonania.$probe_name.$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
    key="${bundle_id:l}"
    make_probe_app "$bundle_id"

    # 4. Resolve the active display and a non-active target Desktop by UUID.
    local original_active_space_id display original_active_uuid
    original_active_space_id="$("$probe_executable" --active-space)"
    display="$("$probe_executable" --active-display-identifier)"
    # Record the active Desktop by its STABLE UUID as well, so restore can return
    # there even after a boundary re-mints the integer managed space IDs.
    original_active_uuid="$(/usr/bin/jq -r \
        --arg display "$display" \
        --argjson id "$original_active_space_id" '
        [.SpacesDisplayConfiguration["Management Data"].Monitors[]
        | select(."Display Identifier" == $display)
        | .Spaces[]
        | select(.ManagedSpaceID == $id)
        | .uuid][0] // ""
    ' "$store_snapshot_json")"

    local target
    target="$(/usr/bin/jq -r \
        --arg display "$display" \
        --argjson current "$original_active_space_id" '
        [.SpacesDisplayConfiguration["Management Data"].Monitors[]
        | select(."Display Identifier" == $display)
        | .Spaces[]
        | select(has("TileLayoutManager") | not)
        | select(.ManagedSpaceID != $current and .uuid != "")
        | [.ManagedSpaceID, .uuid]][0] // empty
    ' "$store_snapshot_json")"

    if [[ -z "$target" ]]; then
        print -u2 "SKIP: this test needs at least one non-current Desktop (with a UUID) on the active display."
        # The EXIT trap performs the rollback and cleanup.
        exit 2
    fi
    local target_id target_uuid
    target_id="$(printf '%s' "$target" | /usr/bin/jq -r '.[0]')"
    target_uuid="$(printf '%s' "$target" | /usr/bin/jq -r '.[1]')"

    # 5. Pre-seed an UNMANAGED binding so we can prove the adapter preserves it
    #    across Apply and across the session boundary.
    local unmanaged_key unmanaged_uuid
    unmanaged_key="com.taimonania.unmanaged.session.$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr 'A-Z' 'a-z')"
    unmanaged_uuid="$target_uuid"
    /usr/bin/defaults write com.apple.spaces app-bindings -dict-add "$unmanaged_key" "$unmanaged_uuid"

    # 6. Apply the managed Assignment THROUGH THE PRODUCTION ADAPTER.
    local bindings_json owned_json
    bindings_json="$(/usr/bin/jq -n --arg a "$bundle_id" --arg av "$target_uuid" '{($a): $av}')"
    owned_json="$(/usr/bin/jq -n --arg a "$bundle_id" '[$a]')"
    swift run --package-path "$repo_dir" DeskLayouterDesktopPlacementTests "$bindings_json" "$owned_json"
    /bin/sleep "$post_dock_delay"

    # 7. Persist metadata for the verify/restore phases.
    /usr/bin/jq -n \
        --arg bundle_id "$bundle_id" \
        --arg key "$key" \
        --arg target_uuid "$target_uuid" \
        --argjson arm_target_managed_space_id "$target_id" \
        --arg unmanaged_key "$unmanaged_key" \
        --arg unmanaged_uuid "$unmanaged_uuid" \
        --argjson original_active_space_id "$original_active_space_id" \
        --arg original_active_uuid "$original_active_uuid" \
        --argjson original_bindings_present "$original_present" \
        --arg active_display_identifier "$display" \
        '{
            bundle_id: $bundle_id,
            key: $key,
            target_uuid: $target_uuid,
            arm_target_managed_space_id: $arm_target_managed_space_id,
            unmanaged_key: $unmanaged_key,
            unmanaged_uuid: $unmanaged_uuid,
            original_active_space_id: $original_active_space_id,
            original_active_uuid: $original_active_uuid,
            original_bindings_present: $original_bindings_present,
            active_display_identifier: $active_display_identifier
        }' > "$metadata"

    # arm succeeded: keep the armed state for the human-gated boundary.
    arm_succeeded=1
    trap - EXIT INT TERM

    print ""
    print "=== ARMED ==="
    print "macOS build: $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
    print "probe bundle id: $bundle_id"
    print "assigned to Desktop UUID: $target_uuid (managed space id at arm time: $target_id)"
    print "unmanaged binding seeded: $unmanaged_key"
    print "state dir: $state_dir"
    print ""
    print "NEXT (human-gated):"
    print "  1. Log out and back in (or reboot)."
    print "  2. Switch to a DIFFERENT Desktop than the assigned one."
    print "  3. Run:  $self verify"
    print ""
    print "This script has NOT logged out or rebooted. Do that yourself when ready."
    print "To abandon the test without a boundary, run:  $self restore"
}

# --- verify ---------------------------------------------------------------

do_verify() {
    if [[ ! -f "$metadata" || ! -x "$probe_executable" ]]; then
        print -u2 "FAIL: no armed state found. Run '$self arm' first."
        exit 1
    fi

    local bundle_id key target_uuid unmanaged_key unmanaged_uuid display
    bundle_id="$(/usr/bin/jq -r '.bundle_id' "$metadata")"
    key="$(/usr/bin/jq -r '.key' "$metadata")"
    target_uuid="$(/usr/bin/jq -r '.target_uuid' "$metadata")"
    unmanaged_key="$(/usr/bin/jq -r '.unmanaged_key' "$metadata")"
    unmanaged_uuid="$(/usr/bin/jq -r '.unmanaged_uuid' "$metadata")"
    display="$(/usr/bin/jq -r '.active_display_identifier' "$metadata")"

    print "recorded macOS build:"
    /bin/cat "$sw_vers_file"
    print ""

    local failed=0

    # Read-back evidence (necessary but NOT sufficient).
    local persisted_target persisted_unmanaged
    persisted_target="$(persistent_bindings_json | /usr/bin/jq -r --arg k "$key" '.[$k] // ""')"
    persisted_unmanaged="$(persistent_bindings_json | /usr/bin/jq -r --arg k "$unmanaged_key" '.[$k] // ""')"
    if [[ "$persisted_target" == "$target_uuid" ]]; then
        print "PASS: managed Assignment survived the boundary in the persistent store"
    else
        print -u2 "FAIL: managed Assignment missing after boundary — expected $target_uuid, got '$persisted_target'"
        failed=1
    fi
    if [[ "$persisted_unmanaged" == "$unmanaged_uuid" ]]; then
        print "PASS: unmanaged binding preserved across the boundary"
    else
        print -u2 "FAIL: unmanaged binding lost after boundary — expected $unmanaged_uuid, got '$persisted_unmanaged'"
        failed=1
    fi

    # Resolve the CURRENT managed space id for the target Desktop UUID (IDs may
    # be re-minted across the boundary; the UUID is stable).
    local current_target_id
    current_target_id="$(managed_space_id_for_uuid "$display" "$target_uuid")"
    if [[ -z "$current_target_id" ]]; then
        print -u2 "FAIL: the assigned Desktop (UUID $target_uuid) no longer exists on the active display"
        do_restore
        exit 1
    fi

    # ACTUAL placement proof: launch the fully-quit probe from the current
    # (different) Desktop WITHOUT Desk Layouter running and inspect its window.
    /usr/bin/pkill -f "$probe_name" >/dev/null 2>&1 || true
    for _ in {1..30}; do /usr/bin/pgrep -f "$probe_name" >/dev/null 2>&1 || break; /bin/sleep 0.1; done

    local winfile="$state_dir/window-verify"
    /bin/rm -f "$winfile"
    /usr/bin/open -n "$probe_app" --args --window-number-file "$winfile"
    local pid=""
    for _ in {1..350}; do
        pid="$(/usr/bin/pgrep -f "$probe_executable" | head -n 1 || true)"
        [[ -n "$pid" ]] && break
        /bin/sleep 0.1
    done
    if [[ -z "$pid" ]]; then
        print -u2 "FAIL: probe did not launch"
        do_restore
        exit 1
    fi
    for _ in {1..100}; do [[ -s "$winfile" ]] && break; /bin/sleep 0.1; done
    if [[ ! -s "$winfile" ]]; then
        print -u2 "FAIL: probe did not report its window"
        do_restore
        exit 1
    fi
    local win obs=""
    win="$(<"$winfile")"
    for _ in {1..40}; do
        obs="$("$probe_executable" --inspect "$pid" "$win" 2>/dev/null || true)"
        [[ -n "$obs" ]] && break
        /bin/sleep 0.1
    done
    local observed
    observed="$(printf '%s' "$obs" | /usr/bin/jq -c '[.[].managedSpaceIDs[]] | unique | sort' 2>/dev/null || echo '[]')"
    if [[ "$observed" == "[$current_target_id]" ]]; then
        print "PASS: probe window actually opened on its assigned Desktop (managed space $current_target_id) with Desk Layouter not running"
    else
        print -u2 "FAIL: probe landed on $observed, expected [$current_target_id]"
        failed=1
    fi

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
