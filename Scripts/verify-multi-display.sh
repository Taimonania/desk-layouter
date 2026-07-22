#!/bin/zsh

set -eu

# Transactional, human-gated real-system test for issue #22.
#
# `arm` tests disposable Assignments and Layouts on the currently visible
# Desktop of one built-in and one external extended Display, then restores every
# binding/window/resource it changed. The human changes which Display is Main in
# System Settings and runs `verify`, which repeats the same test and requires the
# other physical Display to hold Main. Main-role changes are deliberately not
# automated. `restore` is idempotent and safe after an interrupted phase.

mode="${1:-}"
case "$mode" in
    arm|verify|restore) ;;
    *) print -u2 "usage: $0 arm | verify | restore"; exit 2 ;;
esac

state_base="${TMPDIR:-/tmp}"
state_base="${state_base%/}"
state_root="$state_base/desk-layouter-multidisplay-state"
snapshot_json="$state_root/topology.json"
original_bindings="$state_root/original-app-bindings.json"
config_json="$state_root/configuration.json"
probe_name="DeskLayouterMultiDisplayProbe"
probe_binary="$state_root/$probe_name"
probe_app_a="$state_root/${probe_name}A.app"
probe_app_b="$state_root/${probe_name}B.app"
probe_exe_a="$probe_app_a/Contents/MacOS/$probe_name"
probe_exe_b="$probe_app_b/Contents/MacOS/$probe_name"
window_file_a="$state_root/window-a"
window_file_b="$state_root/window-b"
phase_complete=0

restore_bindings() {
    [[ -f "$original_bindings" ]] || return 0
    /usr/bin/defaults delete com.apple.spaces app-bindings >/dev/null 2>&1 || true
    while IFS= read -r entry; do
        key="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.key')"
        value="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.value')"
        /usr/bin/defaults write com.apple.spaces app-bindings -dict-add "$key" "$value"
    done < <(/usr/bin/jq -r 'to_entries[] | @base64' "$original_bindings")
    if [[ -x "$probe_exe_a" ]]; then
        "$probe_exe_a" --set-session-bindings "$original_bindings" >/dev/null 2>&1 || true
    fi
    /usr/bin/killall Dock >/dev/null 2>&1 || true
}

stop_probes() {
    /usr/bin/pkill -f "$probe_name" >/dev/null 2>&1 || true
    /bin/rm -f "$window_file_a" "$window_file_b"
}

remove_state() {
    case "$state_root" in
        "$state_base"/desk-layouter-multidisplay-state)
            /bin/rm -rf -- "$state_root"
            ;;
        *)
            print -u2 "Refusing to remove unexpected state directory: $state_root"
            return 1
            ;;
    esac
}

cleanup_phase() {
    exit_code=$?
    trap - EXIT INT TERM HUP
    stop_probes
    restore_bindings || exit_code=1
    if (( phase_complete == 0 && mode == arm )); then
        remove_state || exit_code=1
    fi
    exit "$exit_code"
}

if [[ "$mode" == restore ]]; then
    stop_probes
    restore_bindings
    remove_state
    print "PASS: original bindings, live session, probe windows, and probe resources restored"
    exit 0
fi

if [[ "$mode" == arm ]]; then
    if [[ -e "$state_root" ]]; then
        print -u2 "A multi-Display test is already armed at $state_root. Run restore first."
        exit 1
    fi
    /bin/mkdir -p "$state_root"
    original_store="$state_root/original-spaces.plist"
    /usr/bin/defaults export com.apple.spaces "$original_store" >/dev/null
    /usr/bin/plutil -convert json -o "$state_root/original-spaces.json" "$original_store"
    /usr/bin/jq '."app-bindings" // {}' "$state_root/original-spaces.json" > "$original_bindings"

    /usr/bin/swiftc -framework AppKit -framework CoreGraphics \
        "${0:A:h}/desktop-placement-probe.swift" -o "$probe_binary"
    probe_bundle_a="com.taimonania.$probe_name.a.$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
    probe_bundle_b="com.taimonania.$probe_name.b.$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
    print -r -- "$probe_bundle_a" > "$state_root/bundle-a"
    print -r -- "$probe_bundle_b" > "$state_root/bundle-b"

    make_probe() {
        local app="$1" bundle="$2"
        /bin/mkdir -p "$app/Contents/MacOS"
        /bin/cp "$probe_binary" "$app/Contents/MacOS/$probe_name"
        /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
        /usr/libexec/PlistBuddy \
            -c "Add :CFBundleExecutable string $probe_name" \
            -c "Add :CFBundleIdentifier string $bundle" \
            -c "Add :CFBundleName string $probe_name" \
            -c 'Add :CFBundlePackageType string APPL' \
            -c 'Add :CFBundleVersion string 1' \
            "$app/Contents/Info.plist"
    }
    make_probe "$probe_app_a" "$probe_bundle_a"
    make_probe "$probe_app_b" "$probe_bundle_b"
else
    [[ -d "$state_root" && -f "$state_root/first-main-uuid" ]] || {
        print -u2 "No armed multi-Display test was found. Run arm first."
        exit 1
    }
fi

trap cleanup_phase EXIT INT TERM HUP

swift run DeskLayouterMultiDisplaySystemTests snapshot > "$snapshot_json"

separate="$(/usr/bin/jq -r '.displaysHaveSeparateSpaces' "$snapshot_json")"
section_count="$(/usr/bin/jq '.sections | length' "$snapshot_json")"
built_count="$(/usr/bin/jq '[.sections[] | select(.isBuiltIn == true and .isMirrored == false)] | length' "$snapshot_json")"
external_count="$(/usr/bin/jq '[.sections[] | select(.isBuiltIn == false and .isMirrored == false)] | length' "$snapshot_json")"
if [[ "$separate" != true || "$section_count" -lt 2 || "$built_count" -lt 1 || "$external_count" -lt 1 ]]; then
    print -u2 "SKIP: requires separate Spaces with one active built-in and one active external extended Display"
    exit 2
fi

main_uuid="$(/usr/bin/jq -r '.sections[] | select(.isMain == true) | .identity.colorSyncUUID' "$snapshot_json")"
[[ -n "$main_uuid" && "$main_uuid" != null ]] || { print -u2 "FAIL: no unique Main Display"; exit 1; }
if [[ "$mode" == arm ]]; then
    print -r -- "$main_uuid" > "$state_root/first-main-uuid"
else
    first_main="$(<"$state_root/first-main-uuid")"
    if [[ "$main_uuid" == "$first_main" ]]; then
        print -u2 "WAIT: Main is still $main_uuid. Change Main to the other physical Display, then run verify again."
        phase_complete=1
        exit 3
    fi
fi

probe_bundle_a="$(<"$state_root/bundle-a")"
probe_bundle_b="$(<"$state_root/bundle-b")"

# Use each Display's currently visible Desktop so Layout can be enacted now.
/usr/bin/jq \
    --arg bundleA "$probe_bundle_a" \
    --arg bundleB "$probe_bundle_b" '
    def app($bundle; $name; $section; $column): {
        bundleIdentifier: $bundle,
        displayName: $name,
        display: $section.identity,
        desktopNumber: $section.activeDesktopNumber,
        layout: {
            horizontalDivision: 2,
            verticalDivision: 1,
            columnSpan: {start: $column, end: $column},
            rowSpan: {start: 0, end: 0}
        }
    };
    (.sections | map(select(.isBuiltIn == true and .isMirrored == false)) | first) as $built |
    (.sections | map(select(.isBuiltIn == false and .isMirrored == false)) | first) as $external |
    if ($built.activeDesktopNumber == null or $external.activeDesktopNumber == null) then error("active Desktop unavailable") else
    {managedApplications: [
        app($bundleA; "Built-in probe"; $built; 0),
        app($bundleB; "External probe"; $external; 1)
    ], pendingRemovals: []} end
' "$snapshot_json" > "$config_json"

swift run DeskLayouterMultiDisplaySystemTests apply "$config_json"
/bin/sleep "${MULTIDISPLAY_PROBE_DOCK_DELAY:-2}"

launch_probe() {
    local app="$1" exe="$2" window_file="$3"
    /usr/bin/open -n "$app" --args --window-number-file "$window_file"
    for _ in {1..100}; do [[ -s "$window_file" ]] && return 0; /bin/sleep 0.1; done
    print -u2 "FAIL: $app did not expose a probe window"
    return 1
}
launch_probe "$probe_app_a" "$probe_exe_a" "$window_file_a"
launch_probe "$probe_app_b" "$probe_exe_b" "$window_file_b"
/bin/sleep 0.5

# Verify the disposable windows landed on the assigned managed Spaces. A
# persistent app-binding read-back alone is not proof that the live session
# honored it, so inspect each real window through WindowServer before arranging.
current_spaces="$state_root/current-spaces-$mode.json"
/usr/bin/defaults export com.apple.spaces - \
    | /usr/bin/plutil -convert json -o "$current_spaces" -

verify_window_space() {
    local label="$1" exe="$2" window_file="$3" section_filter="$4"
    local display_key desktop_number expected_id process_id window_number inspection
    display_key="$(/usr/bin/jq -r \
        "$section_filter | if .isMain then \"Main\" else .identity.colorSyncUUID end" \
        "$snapshot_json")"
    desktop_number="$(/usr/bin/jq -r "$section_filter | .activeDesktopNumber" "$snapshot_json")"
    expected_id="$(/usr/bin/jq -r \
        --arg key "$display_key" --argjson index "$(( desktop_number - 1 ))" '
        [.SpacesDisplayConfiguration["Management Data"].Monitors[]
          | select(.["Display Identifier"] == $key and (.Spaces | type == "array"))
          | [.Spaces[] | select(has("TileLayoutManager") | not) | .ManagedSpaceID]
        ][0][$index] // empty
        ' "$current_spaces")"
    [[ -n "$expected_id" ]] || {
        print -u2 "FAIL: could not resolve $label's assigned managed Space"
        return 1
    }
    process_id="$(/usr/bin/pgrep -n -f "$exe")"
    window_number="$(<"$window_file")"
    inspection="$("$exe" --inspect "$process_id" "$window_number")"
    /usr/bin/jq -e --argjson expected "$expected_id" \
        '.[0].managedSpaceIDs == [$expected]' <<< "$inspection" >/dev/null || {
        print -u2 "FAIL: $label probe window did not land on managed Space $expected_id"
        print -u2 "$inspection"
        return 1
    }
}

verify_window_space \
    "built-in" "$probe_exe_a" "$window_file_a" \
    '.sections | map(select(.isBuiltIn == true and .isMirrored == false)) | first'
verify_window_space \
    "external" "$probe_exe_b" "$window_file_b" \
    '.sections | map(select(.isBuiltIn == false and .isMirrored == false)) | first'

arrange_output="$state_root/arrange-$mode.json"
swift run DeskLayouterMultiDisplaySystemTests arrange "$config_json" > "$arrange_output"
arranged_count="$(/usr/bin/jq '[.[].arranged[]] | length' "$arrange_output")"
resisted_count="$(/usr/bin/jq '[.[].resisted[]] | length' "$arrange_output")"
display_report_count="$(/usr/bin/jq '[.[].displayUUID] | unique | length' "$arrange_output")"
if (( arranged_count != 2 || resisted_count != 0 || display_report_count != 2 )); then
    print -u2 "FAIL: expected two arranged probes reported under two physical Displays"
    /bin/cat "$arrange_output" >&2
    exit 1
fi

# The Arrange report is based on AX frame read-back, so `arranged` proves each
# disposable window reached its Layout on that destination Display's usable area.
current_bindings="$state_root/current-bindings.json"
/usr/bin/defaults export com.apple.spaces - \
    | /usr/bin/plutil -convert json -o - - \
    | /usr/bin/jq '."app-bindings" // {}' > "$current_bindings"
probe_key_a="${probe_bundle_a:l}"
probe_key_b="${probe_bundle_b:l}"
preserved="$(/usr/bin/jq -n \
    --slurpfile before "$original_bindings" --slurpfile after "$current_bindings" \
    --arg a "$probe_key_a" --arg b "$probe_key_b" \
    '($after[0] | del(.[$a], .[$b])) == $before[0]')"
[[ "$preserved" == true ]] || { print -u2 "FAIL: a non-probe app-binding changed"; exit 1; }

stop_probes
restore_bindings
phase_complete=1

if [[ "$mode" == arm ]]; then
    print "PASS: built-in + external Assignments and Layouts verified with $main_uuid as Main; all changed state restored"
    print "Now change Main to the other physical Display in System Settings, then run: make multi-display-verify"
else
    remove_state
    print "PASS: both physical Displays were verified as Main; bindings, windows, active Desktops, and probe resources restored"
fi
