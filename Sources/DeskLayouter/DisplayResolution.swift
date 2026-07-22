import AppKit
import CoreGraphics
import Darwin
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
    public let identity: DisplayIdentity?
    /// The master display this one mirrors, or `0` when it is not a mirror
    /// secondary. Mirror secondaries collapse into their master's logical
    /// Display, so a mirrored group counts as one Display rather than several.
    public let mirrorsDisplayID: UInt32
    public let isBuiltIn: Bool
    public let bounds: DisplayBounds

    public init(
        displayID: UInt32,
        isMain: Bool,
        mirrorsDisplayID: UInt32,
        identity: DisplayIdentity? = nil,
        isBuiltIn: Bool = false,
        bounds: DisplayBounds = DisplayBounds(x: 0, y: 0, width: 0, height: 0)
    ) {
        self.displayID = displayID
        self.isMain = isMain
        self.mirrorsDisplayID = mirrorsDisplayID
        self.identity = identity
        self.isBuiltIn = isBuiltIn
        self.bounds = bounds
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

/// Mission Control settings that change whether physical Displays are valid
/// independent destinations and whether positional Desktop numbers may move.
public protocol DisplaySettingsProviding {
    var displaysHaveSeparateSpaces: Bool { get }
    var automaticallyRearrangesSpaces: Bool { get }
}

public struct SystemDisplaySettingsProvider: DisplaySettingsProviding {
    public init() {}

    public var displaysHaveSeparateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }

    public var automaticallyRearrangesSpaces: Bool {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")
        if let number = domain?["mru-spaces"] as? NSNumber { return number.boolValue }
        return false
    }
}

/// Reads the live active managed Space ID from the current WindowServer session.
///
/// Runtime Arrange (#61) resolves which Desktop is actually in front of the user
/// from this live value rather than the exported `com.apple.spaces` store's
/// `"Current Space"`, which can lag behind the session. Injectable so
/// `MacOSSpacesAdapter` can be exercised against a controlled active Space
/// without touching WindowServer.
public protocol ActiveSpaceProviding {
    /// The live active managed Space ID, or `nil` when it cannot be read (an
    /// unavailable private ABI or a WindowServer that reports no space). A `nil`
    /// makes the active Desktop unresolvable, so Arrange fails closed.
    func activeManagedSpaceID() throws -> UInt64?
}

/// Reads the currently visible managed Space on every logical Display. The keys
/// use the same runtime-only private identifiers as the Spaces store (`Main` or
/// a non-main physical UUID).
public protocol ActiveDisplaySpacesProviding {
    func activeManagedSpaceIDsByDisplayKey() throws -> [String: UInt64]
}

private typealias ActiveSpaceMainConnection = @convention(c) () -> Int32
private typealias ActiveSpaceFunction = @convention(c) (Int32) -> UInt64

/// The production active-Space reader, resolving the private SkyLight
/// `SLSGetActiveSpace` symbol dynamically (matching `Scripts/desktop-placement-probe.swift`).
/// An unavailable symbol resolves to `nil` so the caller fails closed rather than
/// throwing — Arrange then reports it could not determine the active Desktop.
public struct SkyLightActiveSpaceProvider: ActiveSpaceProviding {
    public init() {}

    public func activeManagedSpaceID() throws -> UInt64? {
        guard let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            return nil
        }
        defer { dlclose(skyLight) }

        guard
            let mainConnectionSymbol = dlsym(skyLight, "SLSMainConnectionID")
                ?? dlsym(skyLight, "CGSMainConnectionID"),
            let activeSpaceSymbol = dlsym(skyLight, "SLSGetActiveSpace")
                ?? dlsym(skyLight, "CGSGetActiveSpace")
        else {
            return nil
        }

        let mainConnection = unsafeBitCast(mainConnectionSymbol, to: ActiveSpaceMainConnection.self)
        let getActiveSpace = unsafeBitCast(activeSpaceSymbol, to: ActiveSpaceFunction.self)
        return getActiveSpace(mainConnection())
    }
}

private typealias CopyManagedDisplaySpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?

/// Production per-Display active-Space reader. `SLSCopyManagedDisplaySpaces`
/// exposes the live WindowServer view for every Display; unlike the exported
/// preferences store it is not a lagging persistence snapshot.
public struct SkyLightActiveDisplaySpacesProvider: ActiveDisplaySpacesProviding {
    public init() {}

    public func activeManagedSpaceIDsByDisplayKey() throws -> [String: UInt64] {
        guard let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else { throw SpacesAdapterError.sessionBindingAPIUnavailable }
        defer { dlclose(skyLight) }
        guard
            let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID")
                ?? dlsym(skyLight, "CGSMainConnectionID"),
            let copySymbol = dlsym(skyLight, "SLSCopyManagedDisplaySpaces")
                ?? dlsym(skyLight, "CGSCopyManagedDisplaySpaces")
        else { throw SpacesAdapterError.sessionBindingAPIUnavailable }

        let connection = unsafeBitCast(connectionSymbol, to: ActiveSpaceMainConnection.self)
        let copy = unsafeBitCast(copySymbol, to: CopyManagedDisplaySpacesFunction.self)
        guard let array = copy(connection())?.takeRetainedValue() as? [[String: Any]] else {
            throw SpacesAdapterError.storeFormatChanged
        }
        var result: [String: UInt64] = [:]
        for display in array {
            guard
                let key = display["Display Identifier"] as? String,
                let current = display["Current Space"] as? [String: Any],
                let id = current["ManagedSpaceID"] as? NSNumber
            else { continue }
            result[key] = id.uint64Value
        }
        return result
    }
}

/// Pure display-topology and private-store resolution.
///
/// Kept separate from the CoreGraphics/`defaults` I/O so both rules can be
/// unit-tested directly: which logical Display is active, and which ordered
/// Desktops that Display currently hosts.
public enum DisplayResolution {
    /// Active physical destinations, with mirror secondaries collapsed into the
    /// primary Display macOS exposes as the independent Desktop host.
    public static func logicalDisplays(from displays: [ActiveDisplay]) -> [ActiveDisplay] {
        displays.filter { $0.mirrorsDisplayID == 0 }
    }

    /// Resolves the complete active topology, grouping mirror members around
    /// their primary and reading every extended Display's own ordered Desktops.
    public static func topology(
        from displays: [ActiveDisplay],
        store: [String: Any],
        displaysHaveSeparateSpaces: Bool,
        automaticallyRearrangesSpaces: Bool
    ) throws -> DisplayTopologySnapshot {
        let primaries = logicalDisplays(from: displays)
        guard !primaries.isEmpty else { throw SpacesAdapterError.noActiveDisplay }

        let sections = try primaries.map { primary -> DisplayDesktopSectionSnapshot in
            guard let primaryIdentity = primary.identity else {
                throw SpacesAdapterError.displayEnumerationFailed
            }
            let mirrorMembers = displays.filter {
                $0.displayID == primary.displayID || $0.mirrorsDisplayID == primary.displayID
            }
            let identities = mirrorMembers.compactMap(\.identity)
            guard identities.count == mirrorMembers.count else {
                throw SpacesAdapterError.displayEnumerationFailed
            }

            let desktopUUIDs: [String]
            if displaysHaveSeparateSpaces || primary.isMain {
                desktopUUIDs = try orderedDesktopUUIDs(
                    fromStore: store,
                    displayKey: try displayKey(for: primary)
                )
            } else {
                // Without separate Spaces a non-main Display is not an
                // independent destination. Keep the section/identity visible,
                // but expose no false Desktop targets.
                desktopUUIDs = []
            }
            return DisplayDesktopSectionSnapshot(
                primaryDisplay: primaryIdentity,
                memberDisplays: identities,
                isMain: primary.isMain,
                isBuiltIn: primary.isBuiltIn,
                bounds: primary.bounds,
                orderedDesktopUUIDs: desktopUUIDs
            )
        }
        return DisplayTopologySnapshot(
            displaysHaveSeparateSpaces: displaysHaveSeparateSpaces,
            automaticallyRearrangesSpaces: automaticallyRearrangesSpaces,
            sections: sections
        )
    }

    /// The runtime-only private monitor alias for an active physical Display.
    /// `Main` is derived from the current role and never enters persistence.
    public static func displayKey(for display: ActiveDisplay) throws -> String {
        if display.isMain { return "Main" }
        guard let identity = display.identity else {
            throw SpacesAdapterError.displayEnumerationFailed
        }
        return identity.colorSyncUUID
    }

    /// Resolves one persisted identity to one currently active logical Display.
    public static func activeDisplay(
        matching identity: DisplayIdentity,
        in displays: [ActiveDisplay]
    ) throws -> ActiveDisplay {
        let matches = logicalDisplays(from: displays).filter {
            $0.identity?.identifiesSameDisplay(as: identity) == true
        }
        guard matches.count == 1, let match = matches.first else {
            throw SpacesAdapterError.noActiveDisplay
        }
        return match
    }

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
        let logicalDisplays = logicalDisplays(from: displays)
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

    /// Resolves the 1-based number of the Desktop whose managed Space ID is
    /// `managedSpaceID` from an exported `com.apple.spaces` store, matching the
    /// numbering of ``orderedDesktopUUIDs(fromStore:displayKey:)`` (Desktop 1 is
    /// the first ordered Desktop). Returns `nil` when the ordered Desktops cannot
    /// be read or none carries that managed Space ID — Arrange treats an
    /// unmappable active Space as "unknown" and fails closed rather than guessing.
    ///
    /// `managedSpaceID` is the LIVE active managed Space ID read from WindowServer
    /// (see ``ActiveSpaceProviding``), deliberately used in place of the store's
    /// `"Current Space"` value, which can lag behind the live session (issue #61).
    /// The number is that ID's position in the same ordered,
    /// TileLayoutManager-filtered Desktop list Assignment already uses.
    public static func desktopNumber(
        forManagedSpaceID managedSpaceID: UInt64,
        fromStore store: [String: Any],
        displayKey: String
    ) -> Int? {
        guard
            let managedSpaceIDs = orderedManagedSpaceIDs(fromStore: store, displayKey: displayKey),
            let index = managedSpaceIDs.firstIndex(of: managedSpaceID)
        else {
            return nil
        }
        return index + 1
    }

    /// The managed Space IDs of the given Display's ordered Desktops, in the same
    /// positional order and with the same TileLayoutManager filtering as
    /// ``orderedDesktopUUIDs(fromStore:displayKey:)``, so an ID's index lines up
    /// with its Desktop number. Returns `nil` when the live monitor entry or its
    /// `Spaces` array is missing.
    private static func orderedManagedSpaceIDs(
        fromStore store: [String: Any],
        displayKey: String
    ) -> [UInt64]? {
        guard
            let displayEntry = monitorEntry(fromStore: store, displayKey: displayKey),
            let desktopEntries = displayEntry["Spaces"] as? [[String: Any]]
        else {
            return nil
        }
        return desktopEntries.compactMap { entry -> UInt64? in
            guard entry["TileLayoutManager"] == nil else { return nil }
            return (entry["ManagedSpaceID"] as? NSNumber)?.uint64Value
        }
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
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
            throw SpacesAdapterError.displayEnumerationFailed
        }

        var displayIdentifiers = Array(
            repeating: CGDirectDisplayID(),
            count: Int(displayCount)
        )
        guard
            CGGetOnlineDisplayList(displayCount, &displayIdentifiers, &displayCount) == .success
        else {
            throw SpacesAdapterError.displayEnumerationFailed
        }

        let mainDisplay = CGMainDisplayID()
        return displayIdentifiers.prefix(Int(displayCount)).filter { identifier in
            CGDisplayIsActive(identifier) != 0 || CGDisplayMirrorsDisplay(identifier) != 0
        }.map { identifier in
            let frame = CGDisplayBounds(identifier)
            return ActiveDisplay(
                displayID: identifier,
                isMain: identifier == mainDisplay,
                mirrorsDisplayID: CGDisplayMirrorsDisplay(identifier),
                identity: displayIdentity(for: identifier),
                isBuiltIn: CGDisplayIsBuiltin(identifier) != 0,
                bounds: DisplayBounds(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                )
            )
        }
    }

    private func displayIdentity(for displayID: CGDirectDisplayID) -> DisplayIdentity? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        let uuidString = CFUUIDCreateString(nil, uuid) as String
        let displayName = NSScreen.screens.first { display in
            (display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }?.localizedName ?? "Display"
        return DisplayIdentity(
            colorSyncUUID: uuidString,
            lastKnownName: displayName,
            vendorID: CGDisplayVendorNumber(displayID),
            modelID: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID)
        )
    }
}
