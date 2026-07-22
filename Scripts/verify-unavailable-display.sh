#!/bin/zsh

set -eu

# Transactional, human-gated real-system coverage for issue #23.
#
# Start with the laptop open and one external Display connected in extended mode:
#
#   arm -> disconnect external -> external-disconnected -> reconnect external
#   -> external-reconnected -> close lid -> lid-closed -> open lid -> lid-open
#
# The harness seeds two disposable managed bindings, then proves an Apply for the
# still-connected Display preserves the other physical Display's binding while it
# is unavailable. Every phase verifies all pre-existing unmanaged bindings. The
# final phase (and any failed phase) restores the original persistent and live
# session bindings and removes every probe resource. `restore` is safe standalone.

mode="${1:-}"
case "$mode" in
    arm|external-disconnected|external-reconnected|lid-closed|lid-open|restore) ;;
    *) print -u2 "usage: $0 arm | external-disconnected | external-reconnected | lid-closed | lid-open | restore"; exit 2 ;;
esac

state_base="${TMPDIR:-/tmp}"
state_base="${state_base%/}"
state_root="$state_base/desk-layouter-unavailable-display-state"
original_bindings="$state_root/original-app-bindings.json"
configuration_json="$state_root/configuration.json"
snapshot_json="$state_root/topology-$mode.json"
plan_json="$state_root/plan-$mode.json"
session_helper="$state_root/session-helper"
phase_file="$state_root/phase"
phase_complete=0

restore_bindings() {
    [[ -f "$original_bindings" ]] || return 0
    /usr/bin/defaults delete com.apple.spaces app-bindings >/dev/null 2>&1 || true
    while IFS= read -r entry; do
        key="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.key')"
        value="$(printf '%s' "$entry" | /usr/bin/base64 -D | /usr/bin/jq -r '.value')"
        /usr/bin/defaults write com.apple.spaces app-bindings -dict-add "$key" "$value"
    done < <(/usr/bin/jq -r 'to_entries[] | @base64' "$original_bindings")
    if [[ -x "$session_helper" ]]; then
        "$session_helper" --set-session-bindings "$original_bindings" >/dev/null 2>&1 || true
    fi
    /usr/bin/killall Dock >/dev/null 2>&1 || true
}

remove_state() {
    case "$state_root" in
        "$state_base"/desk-layouter-unavailable-display-state)
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
    if (( phase_complete == 0 )); then
        restore_bindings || exit_code=1
        remove_state || exit_code=1
    fi
    exit "$exit_code"
}

if [[ "$mode" == restore ]]; then
    restore_bindings
    remove_state
    print "PASS: original bindings, live session, and all unavailable-Display probe resources restored"
    exit 0
fi

if [[ "$mode" == arm ]]; then
    if [[ -e "$state_root" ]]; then
        print -u2 "An unavailable-Display test is already armed at $state_root. Run restore first."
        exit 1
    fi
    /bin/mkdir -p "$state_root"
    original_store="$state_root/original-spaces.plist"
    /usr/bin/defaults export com.apple.spaces "$original_store" >/dev/null
    /usr/bin/plutil -convert json -o "$state_root/original-spaces.json" "$original_store"
    /usr/bin/jq '."app-bindings" // {}' "$state_root/original-spaces.json" > "$original_bindings"
    /usr/bin/swiftc -framework AppKit -framework CoreGraphics \
        "${0:A:h}/desktop-placement-probe.swift" -o "$session_helper"
else
    [[ -d "$state_root" && -f "$phase_file" && -f "$configuration_json" ]] || {
        print -u2 "No armed unavailable-Display test was found. Run arm first."
        exit 1
    }
fi

trap cleanup_phase EXIT INT TERM HUP

expected_previous=""
case "$mode" in
    external-disconnected) expected_previous="armed" ;;
    external-reconnected) expected_previous="external-disconnected" ;;
    lid-closed) expected_previous="external-reconnected" ;;
    lid-open) expected_previous="lid-closed" ;;
esac
if [[ -n "$expected_previous" ]]; then
    actual_previous="$(<"$phase_file")"
    [[ "$actual_previous" == "$expected_previous" ]] || {
        print -u2 "Expected completed phase $expected_previous, found $actual_previous."
        exit 1
    }
fi

swift run DeskLayouterMultiDisplaySystemTests snapshot > "$snapshot_json"
separate="$(/usr/bin/jq -r '.displaysHaveSeparateSpaces' "$snapshot_json")"
[[ "$separate" == true ]] || { print -u2 "SKIP: Displays have separate Spaces must be on"; exit 2; }

has_identity() {
    local uuid="$1"
    /usr/bin/jq -e --arg uuid "$uuid" \
        '[.sections[].memberIdentities[] | select((.colorSyncUUID | ascii_downcase) == ($uuid | ascii_downcase))] | length == 1' \
        "$snapshot_json" >/dev/null
}

verify_unmanaged() {
    local current="$state_root/current-bindings-$mode.json"
    /usr/bin/defaults export com.apple.spaces - \
        | /usr/bin/plutil -convert json -o - - \
        | /usr/bin/jq '."app-bindings" // {}' > "$current"
    /usr/bin/jq -e -n \
        --slurpfile before "$original_bindings" --slurpfile after "$current" \
        --arg built "$(<"$state_root/built-bundle")" \
        --arg external "$(<"$state_root/external-bundle")" \
        '($after[0] | del(.[$built], .[$external])) == $before[0]' >/dev/null || {
        print -u2 "FAIL: an unmanaged binding changed"
        return 1
    }
}

verify_binding() {
    local key="$1" expected="$2"
    current="$(/usr/bin/defaults read com.apple.spaces app-bindings 2>/dev/null \
        | /usr/bin/plutil -convert json -o - - \
        | /usr/bin/jq -r --arg key "$key" '.[$key] // empty')"
    [[ "$current" == "$expected" ]] || {
        print -u2 "FAIL: $key expected $expected, got ${current:-<missing>}"
        return 1
    }
}

if [[ "$mode" == arm ]]; then
    built_count="$(/usr/bin/jq '[.sections[] | select(.isBuiltIn == true and .isMirrored == false)] | length' "$snapshot_json")"
    external_count="$(/usr/bin/jq '[.sections[] | select(.isBuiltIn == false and .isMirrored == false)] | length' "$snapshot_json")"
    if (( built_count != 1 || external_count != 1 )); then
        print -u2 "SKIP: arm requires exactly one built-in and one external extended Display with the lid open"
        exit 2
    fi

    /usr/bin/jq '.sections[] | select(.isBuiltIn == true)' "$snapshot_json" > "$state_root/built-section.json"
    /usr/bin/jq '.sections[] | select(.isBuiltIn == false)' "$snapshot_json" > "$state_root/external-section.json"
    built_uuid="$(/usr/bin/jq -r '.identity.colorSyncUUID' "$state_root/built-section.json")"
    external_uuid="$(/usr/bin/jq -r '.identity.colorSyncUUID' "$state_root/external-section.json")"
    print -r -- "$built_uuid" > "$state_root/built-uuid"
    print -r -- "$external_uuid" > "$state_root/external-uuid"

    built_bundle="com.taimonania.unavailable.builtin.$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
    external_bundle="com.taimonania.unavailable.external.$(/usr/bin/uuidgen | /usr/bin/tr -d '-' | /usr/bin/tr '[:upper:]' '[:lower:]')"
    print -r -- "$built_bundle" > "$state_root/built-bundle"
    print -r -- "$external_bundle" > "$state_root/external-bundle"

    /usr/bin/jq -n \
        --slurpfile built "$state_root/built-section.json" \
        --slurpfile external "$state_root/external-section.json" \
        --arg builtBundle "$built_bundle" \
        --arg externalBundle "$external_bundle" '{
            managedApplications: [
                {bundleIdentifier: $builtBundle, displayName: "Built-in unavailable probe", display: $built[0].identity, desktopNumber: 1},
                {bundleIdentifier: $externalBundle, displayName: "External unavailable probe", display: $external[0].identity, desktopNumber: 1}
            ],
            pendingRemovals: []
        }' > "$configuration_json"

    swift run DeskLayouterMultiDisplaySystemTests apply "$configuration_json"
    built_binding="$(/usr/bin/jq -r '.desktopUUIDs[0]' "$state_root/built-section.json")"
    external_binding="$(/usr/bin/jq -r '.desktopUUIDs[0]' "$state_root/external-section.json")"
    print -r -- "$built_binding" > "$state_root/built-binding"
    print -r -- "$external_binding" > "$state_root/external-binding"
    verify_binding "$built_bundle" "$built_binding"
    verify_binding "$external_bundle" "$external_binding"
    verify_unmanaged
    print -r -- "armed" > "$phase_file"
    phase_complete=1
    print "PASS: disposable built-in and external bindings seeded without changing unmanaged bindings"
    print "Disconnect the external Display, then run: make unavailable-display-external-disconnected"
    exit 0
fi

built_uuid="$(<"$state_root/built-uuid")"
external_uuid="$(<"$state_root/external-uuid")"
built_bundle="$(<"$state_root/built-bundle")"
external_bundle="$(<"$state_root/external-bundle")"
built_binding="$(<"$state_root/built-binding")"
external_binding="$(<"$state_root/external-binding")"

case "$mode" in
    external-disconnected)
        if has_identity "$external_uuid" || ! has_identity "$built_uuid"; then
            print -u2 "WAIT: disconnect the external Display while leaving the laptop Display available, then retry."
            phase_complete=1
            exit 3
        fi
        swift run DeskLayouterMultiDisplaySystemTests plan "$configuration_json" > "$plan_json"
        /usr/bin/jq -e --arg offline "$external_bundle" --arg connected "$built_bundle" \
            '(.preservations == [$offline]) and (.updates | has($connected)) and (.invalidDesktopAssignments == []) and .canMutate' \
            "$plan_json" >/dev/null || { print -u2 "FAIL: disconnected external was not preserved alongside the connected update"; exit 1; }
        swift run DeskLayouterMultiDisplaySystemTests apply "$configuration_json"
        verify_binding "$external_bundle" "$external_binding"
        verify_unmanaged
        print -r -- "external-disconnected" > "$phase_file"
        phase_complete=1
        print "PASS: unrelated built-in Apply preserved the disconnected external binding and every unmanaged binding"
        print "Reconnect the exact external Display, then run: make unavailable-display-external-reconnected"
        ;;
    external-reconnected)
        if ! has_identity "$external_uuid" || ! has_identity "$built_uuid"; then
            print -u2 "WAIT: reconnect the original external Display with the laptop lid open, then retry."
            phase_complete=1
            exit 3
        fi
        swift run DeskLayouterMultiDisplaySystemTests plan "$configuration_json" > "$plan_json"
        /usr/bin/jq -e --arg built "$built_bundle" --arg external "$external_bundle" \
            '(.preservations == []) and (.invalidDesktopAssignments == []) and (.updates | has($built) and has($external))' \
            "$plan_json" >/dev/null || { print -u2 "FAIL: exact external identity did not recover as a normal destination"; exit 1; }
        verify_binding "$external_bundle" "$external_binding"
        verify_unmanaged
        print -r -- "external-reconnected" > "$phase_file"
        phase_complete=1
        print "PASS: reconnecting the exact external identity restored normal resolution without changing its binding"
        print "Close the laptop lid while keeping the external Display active, then run: make unavailable-display-lid-closed"
        ;;
    lid-closed)
        if has_identity "$built_uuid" || ! has_identity "$external_uuid"; then
            print -u2 "WAIT: close the laptop lid while keeping the external Display active, then retry."
            phase_complete=1
            exit 3
        fi
        swift run DeskLayouterMultiDisplaySystemTests plan "$configuration_json" > "$plan_json"
        /usr/bin/jq -e --arg offline "$built_bundle" --arg connected "$external_bundle" \
            '(.preservations == [$offline]) and (.updates | has($connected)) and (.invalidDesktopAssignments == []) and .canMutate' \
            "$plan_json" >/dev/null || { print -u2 "FAIL: lid transition did not preserve built-in alongside external update"; exit 1; }
        swift run DeskLayouterMultiDisplaySystemTests apply "$configuration_json"
        verify_binding "$built_bundle" "$built_binding"
        verify_unmanaged
        print -r -- "lid-closed" > "$phase_file"
        phase_complete=1
        print "PASS: lid-close transition preserved the built-in binding during an external Apply"
        print "Open the laptop lid, then run: make unavailable-display-lid-open"
        ;;
    lid-open)
        if ! has_identity "$built_uuid" || ! has_identity "$external_uuid"; then
            print -u2 "WAIT: open the laptop lid with the original external Display connected, then retry."
            phase_complete=1
            exit 3
        fi
        swift run DeskLayouterMultiDisplaySystemTests plan "$configuration_json" > "$plan_json"
        /usr/bin/jq -e '.preservations == [] and .invalidDesktopAssignments == [] and (.updates | length == 2)' \
            "$plan_json" >/dev/null || { print -u2 "FAIL: lid-open topology did not restore both normal destinations"; exit 1; }
        verify_binding "$built_bundle" "$built_binding"
        verify_unmanaged
        restore_bindings
        remove_state
        phase_complete=1
        print "PASS: external disconnect/reconnect and lid close/open verified; original bindings, live session, and probe resources restored"
        ;;
esac
