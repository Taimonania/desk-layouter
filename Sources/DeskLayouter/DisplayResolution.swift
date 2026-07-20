import CoreGraphics
import DeskLayouterCore
import Foundation

/// A single active display and the identity facts needed to resolve which
/// logical Display's Desktops the app manages.
///
/// A plain value type so the resolution rules can be unit-tested against
/// built-in-only, external-only, mirrored, zero, and multiple-display
/// topologies without any real hardware or CoreGraphics call.
public struct ActiveDisplay: Equatable, Sendable {
    public let displayID: UInt32
    public let isMain: Bool
    /// The master display this one mirrors, or `0` when it is not a mirror
    /// secondary. Mirror secondaries collapse into their master's logical
    /// Display, so a mirrored group counts as one Display rather than several.
    public let mirrorsDisplayID: UInt32

    public init(displayID: UInt32, isMain: Bool, mirrorsDisplayID: UInt32) {
        self.displayID = displayID
        self.isMain = isMain
        self.mirrorsDisplayID = mirrorsDisplayID
    }
}

/// Enumerates the currently active displays.
///
/// Injectable so `MacOSSpacesAdapter` can be exercised against every supported
/// topology (built-in only, external only with the lid closed, mirrored, zero,
/// and multiple extended) without real hardware.
public protocol DisplayInventoryProviding {
    func activeDisplays() throws -> [ActiveDisplay]
}

/// Pure display-topology and private-store resolution.
///
/// Kept separate from the CoreGraphics/`defaults` I/O so both rules can be
/// unit-tested directly: which logical Display is active, and which ordered
/// Desktops that Display currently hosts.
public enum DisplayResolution {
    /// Collapses mirror sets to logical Displays and returns the private Spaces
    /// store key for the sole active logical Display.
    ///
    /// The sole active Display is, by definition, the macOS main Display, and
    /// its live Spaces are keyed by the private `"Main"` alias regardless of
    /// whether the panel is built in, external with the lid closed, or a
    /// mirrored group. The main role is checked explicitly so Apply's
    /// pre-mutation revalidation rejects a transient topology where the sole
    /// Display is not the main one (issue #18, AC 8). Throws
    /// ``SpacesAdapterError/noActiveDisplay`` when no Display is active and
    /// ``SpacesAdapterError/multipleDisplaysUnsupported`` when more than one
    /// extended logical Display is active — both leave macOS untouched at the
    /// call site.
    public static func activeDisplayKey(for displays: [ActiveDisplay]) throws -> String {
        // A mirror secondary reports the master it mirrors; drop it so a
        // mirrored group resolves to one logical Display rather than many.
        let logicalDisplays = displays.filter { $0.mirrorsDisplayID == 0 }
        guard let soleDisplay = logicalDisplays.first else {
            throw SpacesAdapterError.noActiveDisplay
        }
        guard logicalDisplays.count == 1 else {
            throw SpacesAdapterError.multipleDisplaysUnsupported
        }
        guard soleDisplay.isMain else {
            throw SpacesAdapterError.noActiveDisplay
        }
        return "Main"
    }

    /// Resolves the ordered Desktop UUIDs the given Display currently hosts from
    /// an exported `com.apple.spaces` store.
    ///
    /// Only a store entry that carries a live `Spaces` array is eligible, so
    /// collapsed/historical entries (which carry only `Collapsed Space`) are
    /// skipped even when their `Display Identifier` matches. `TileLayoutManager`
    /// entries are non-Desktop Spaces and are excluded. An empty-string UUID is
    /// a valid Desktop (macOS represents the first Desktop that way), so it is
    /// preserved rather than filtered out.
    public static func orderedDesktopUUIDs(
        fromStore store: [String: Any],
        displayKey: String
    ) throws -> [String] {
        guard
            let displayEntry = monitorEntry(fromStore: store, displayKey: displayKey),
            let desktopEntries = displayEntry["Spaces"] as? [[String: Any]]
        else {
            throw SpacesAdapterError.storeFormatChanged
        }

        let orderedDesktopUUIDs = desktopEntries.compactMap { entry -> String? in
            guard entry["TileLayoutManager"] == nil else {
                return nil
            }
            return entry["uuid"] as? String
        }

        guard !orderedDesktopUUIDs.isEmpty else {
            throw SpacesAdapterError.noDesktopsFound
        }

        return orderedDesktopUUIDs
    }

    /// Resolves the 1-based number of the Desktop currently active on the given
    /// Display from an exported `com.apple.spaces` store, matching the numbering
    /// of ``orderedDesktopUUIDs(fromStore:displayKey:)`` (Desktop 1 is the first
    /// ordered Desktop). Returns `nil` when the current Space cannot be read or is
    /// not one of the Display's ordered Desktops — Arrange treats an unidentified
    /// active Desktop as "unknown" rather than guessing.
    ///
    /// The store records the live current Space per monitor under
    /// `"Current Space" → "uuid"`; the number is that uuid's position in the same
    /// ordered, TileLayoutManager-filtered Desktop list Assignment already uses.
    public static func activeDesktopNumber(
        fromStore store: [String: Any],
        displayKey: String
    ) -> Int? {
        guard
            let displayEntry = monitorEntry(fromStore: store, displayKey: displayKey),
            let currentSpace = displayEntry["Current Space"] as? [String: Any],
            let currentUUID = currentSpace["uuid"] as? String,
            let orderedDesktopUUIDs = try? orderedDesktopUUIDs(fromStore: store, displayKey: displayKey),
            let index = orderedDesktopUUIDs.firstIndex(of: currentUUID)
        else {
            return nil
        }
        return index + 1
    }

    /// The live monitor entry for `displayKey` — the one carrying a `Spaces` array
    /// (collapsed/historical entries, which lack it, are skipped). Both the ordered
    /// Desktop list and the current-Desktop lookup start here, so the store-path
    /// navigation lives in one place.
    private static func monitorEntry(
        fromStore store: [String: Any],
        displayKey: String
    ) -> [String: Any]? {
        guard
            let configuration = store["SpacesDisplayConfiguration"] as? [String: Any],
            let managementData = configuration["Management Data"] as? [String: Any],
            let monitors = managementData["Monitors"] as? [[String: Any]]
        else {
            return nil
        }
        return monitors.first {
            $0["Display Identifier"] as? String == displayKey && $0["Spaces"] != nil
        }
    }
}

/// The production display inventory, reading live CoreGraphics state.
struct CoreGraphicsDisplayInventory: DisplayInventoryProviding {
    func activeDisplays() throws -> [ActiveDisplay] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            throw SpacesAdapterError.displayEnumerationFailed
        }

        var displayIdentifiers = Array(
            repeating: CGDirectDisplayID(),
            count: Int(displayCount)
        )
        guard
            CGGetActiveDisplayList(displayCount, &displayIdentifiers, &displayCount) == .success
        else {
            throw SpacesAdapterError.displayEnumerationFailed
        }

        let mainDisplay = CGMainDisplayID()
        return displayIdentifiers.prefix(Int(displayCount)).map { identifier in
            ActiveDisplay(
                displayID: identifier,
                isMain: identifier == mainDisplay,
                mirrorsDisplayID: CGDisplayMirrorsDisplay(identifier)
            )
        }
    }
}
