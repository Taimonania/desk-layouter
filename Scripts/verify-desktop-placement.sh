#!/bin/zsh

set -eu

probe_name="DeskLayouterDesktopPlacementProbe"
probe_bundle_id="com.taimonania.$probe_name.$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"
probe_tmp_base="${TMPDIR:-/tmp}"
probe_tmp_base="${probe_tmp_base%/}"
probe_root="$(mktemp -d "$probe_tmp_base/desk-layouter-desktop-probe.XXXXXX")"
probe_app="$probe_root/$probe_name.app"
probe_executable="$probe_app/Contents/MacOS/$probe_name"
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

restore_active_space() {
    [[ -x "$probe_executable" && -n "$original_active_space_id" ]] || return

    stable_checks=0
    for _ in {1..20}; do
        current_active_space_id="$($probe_executable --active-space 2>/dev/null || true)"
        [[ -n "$current_active_space_id" ]] || return 1
        if [[ "$current_active_space_id" == "$original_active_space_id" ]]; then
            (( stable_checks += 1 ))
            (( stable_checks >= 4 )) && return
            /bin/sleep 1
            continue
        fi
        stable_checks=0

        current_index="$(printf '%s' "$desktop_managed_space_ids" \
            | /usr/bin/jq -r --argjson id "$current_active_space_id" 'index($id) // -1')"
        original_index="$(printf '%s' "$desktop_managed_space_ids" \
            | /usr/bin/jq -r --argjson id "$original_active_space_id" 'index($id) // -1')"
        if (( current_index < 0 || original_index < 0 )); then
            return 1
        fi
        if (( current_index > original_index )); then
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

cleanup() {
    exit_code=$?
    trap - EXIT INT TERM HUP
    if (( cleanup_started == 0 )); then
        cleanup_started=1
        /usr/bin/pkill -f "$probe_executable" >/dev/null 2>&1 || true
        restore_bindings
        if (( session_bindings_applied == 1 )); then
            "$probe_executable" --set-session-bindings "$original_bindings" || exit_code=1
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

/usr/bin/defaults export com.apple.spaces "$store_snapshot" >/dev/null
/usr/bin/plutil -convert json -o "$store_snapshot_json" "$store_snapshot"
if /usr/bin/jq -e 'has("app-bindings")' "$store_snapshot_json" >/dev/null; then
    original_bindings_present=1
    /usr/bin/jq '."app-bindings"' "$store_snapshot_json" > "$original_bindings"
else
    /usr/bin/jq -n '{}' > "$original_bindings"
fi

mkdir -p "$probe_app/Contents/MacOS"
/usr/bin/swiftc \
    -framework AppKit \
    -framework CoreGraphics \
    "${0:A:h}/desktop-placement-probe.swift" \
    -o "$probe_executable"
/usr/bin/plutil -create xml1 "$probe_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string DeskLayouterDesktopPlacementProbe' \
    -c "Add :CFBundleIdentifier string $probe_bundle_id" \
    -c 'Add :CFBundleName string DeskLayouterDesktopPlacementProbe' \
    -c 'Add :CFBundlePackageType string APPL' \
    -c 'Add :CFBundleVersion string 1' \
    "$probe_app/Contents/Info.plist"

original_active_space_id="$($probe_executable --active-space)"
current_managed_space_id="$original_active_space_id"
built_in_display_identifier="$($probe_executable --built-in-display-identifier)"
desktop_managed_space_ids="$(/usr/bin/jq -c --arg display "$built_in_display_identifier" '
    [.SpacesDisplayConfiguration["Management Data"].Monitors[]
    | select(."Display Identifier" == $display)
    | .Spaces[]
    | select(has("TileLayoutManager") | not)
    | .ManagedSpaceID]
' "$store_snapshot_json")"
target="$(/usr/bin/jq -r \
    --arg display "$built_in_display_identifier" \
    --argjson current "$current_managed_space_id" '
    .SpacesDisplayConfiguration["Management Data"].Monitors[]
    | select(."Display Identifier" == $display)
    | .Spaces[]
    | select(has("TileLayoutManager") | not)
    | select(.ManagedSpaceID != $current and .uuid != "")
    | [.ManagedSpaceID, .uuid]
    | @tsv
' "$store_snapshot_json" | head -n 1)"
if [[ -z "$target" ]]; then
    print -u2 "SKIP: the built-in display needs at least two Desktops"
    exit 2
fi
target_managed_space_id="${target%%$'\t'*}"
target_uuid="${target#*$'\t'}"

session_bindings_applied=1
swift run DeskLayouterDesktopPlacementTests "$probe_bundle_id" "$target_uuid"
/bin/sleep "$post_dock_delay"

window_number_file="$probe_root/window-number"
/usr/bin/open -n "$probe_app" --args --window-number-file "$window_number_file"
probe_pid=""
for _ in {1..350}; do
    probe_pid="$(/usr/bin/pgrep -f "$probe_executable" | head -n 1 || true)"
    [[ -n "$probe_pid" ]] && break
    /bin/sleep 0.1
done
if [[ -z "$probe_pid" ]]; then
    print -u2 "FAIL: disposable probe app did not launch"
    exit 1
fi

for _ in {1..100}; do
    [[ -s "$window_number_file" ]] && break
    /bin/sleep 0.1
done
if [[ ! -s "$window_number_file" ]]; then
    print -u2 "FAIL: disposable probe app did not report its window"
    exit 1
fi
window_number="$(<"$window_number_file")"

observation=""
inspection_error="$probe_root/inspection-error.txt"
for _ in {1..40}; do
    observation="$($probe_executable --inspect "$probe_pid" "$window_number" 2>"$inspection_error" || true)"
    [[ -n "$observation" ]] && break
    /bin/sleep 0.1
done
if [[ -z "$observation" ]]; then
    print -u2 "FAIL: disposable probe app did not create an inspectable window"
    [[ -s "$inspection_error" ]] && /bin/cat "$inspection_error" >&2
    exit 1
fi

observed_space_ids="$(printf '%s' "$observation" | /usr/bin/jq -c \
    '[.[].managedSpaceIDs[]] | unique | sort')"
print "current-managed-space-id=$current_managed_space_id"
print "target-managed-space-id=$target_managed_space_id"
print "target-uuid=$target_uuid"
print "observed-managed-space-ids=$observed_space_ids"

if ! printf '%s' "$observation" | /usr/bin/jq -e --argjson target "$target_managed_space_id" \
    'all(.[]; .managedSpaceIDs == [$target])' >/dev/null; then
    print -u2 "FAIL: newly launched managed app window was not placed only on the target Desktop"
    exit 1
fi

print "PASS: newly launched managed app window was placed on the target Desktop"
