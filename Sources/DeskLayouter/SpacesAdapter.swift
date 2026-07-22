import Darwin
import DeskLayouterCore
import Foundation

public protocol SpacesAdapter {
    func currentDesktopSnapshot() throws -> DesktopSnapshot

    /// Complete active multi-Display topology, including live Main/mirror roles,
    /// ordered Desktops, and Mission Control settings.
    func currentDisplayTopology() throws -> DisplayTopologySnapshot

    /// Physical Displays currently available as independent destinations.
    func availableDisplays() throws -> [DisplayIdentity]

    /// Resolves one selected physical Display to its current ordered Desktops.
    /// Used by migration even while multi-Display editing remains disabled.
    func desktopSnapshot(for display: DisplayIdentity) throws -> DesktopSnapshot

    /// Concrete Desktop UUIDs currently persisted in macOS for the requested
    /// managed bundle identifiers. Migration reads these as the true legacy
    /// last-applied values; it must not infer them from today's Desktop order.
    func persistedDesktopUUIDs(
        for bundleIdentifiers: Set<String>
    ) throws -> [String: String]

    /// The 1-based number of the Desktop currently active on the sole active
    /// Display, matching the numbering of ``currentDesktopSnapshot()`` (Desktop 1
    /// is the first ordered Desktop). Returns `nil` when the active Desktop cannot
    /// be identified — runtime Arrange (#27) uses this to know which Desktop it is
    /// enacting so it can arm the others, and treats `nil` as "unknown".
    func activeDesktopNumber() throws -> Int?

    /// The Desktop currently visible on every connected logical Display.
    func activeDesktopDestinations(
        in topology: DisplayTopologySnapshot
    ) throws -> Set<DesktopAddress>

    /// Applies the managed Assignments to both macOS representations.
    ///
    /// - Parameters:
    ///   - managedBindings: the desired bindings for currently-managed
    ///     Assignments that resolve to an existing Desktop (bundle ID →
    ///     Desktop UUID), as produced by the planner. Bundle IDs are passed
    ///     verbatim; the adapter normalizes them.
    ///   - managedBundleIdentifiers: every bundle identifier the app manages —
    ///     the ownership set. Owned keys absent from `managedBindings` (removed
    ///     or skipped Assignments) are deleted from the macOS bindings, while
    ///     unmanaged entries are preserved untouched.
    ///   - expectedSnapshot: the Desktop snapshot `managedBindings` was resolved
    ///     against. When non-nil, Apply re-reads the active Display's snapshot
    ///     immediately before the first mutation and aborts without writing (and
    ///     without restarting the Dock) if the topology changed underneath — so
    ///     a lid, hot-plug, or main-display change between planning and Apply can
    ///     never write bindings against a stale Desktop order.
    func apply(
        managedBindings: [String: String],
        managedBundleIdentifiers: Set<String>,
        expectedSnapshot: DesktopSnapshot?
    ) throws

    /// Applies a topology-aware mutation plan and revalidates the complete
    /// topology immediately before the first persistent mutation.
    func apply(
        plan: AssignmentApplyPlan,
        expectedTopology: DisplayTopologySnapshot
    ) throws
}

public extension SpacesAdapter {
    func currentDisplayTopology() throws -> DisplayTopologySnapshot {
        let snapshot = try currentDesktopSnapshot()
        guard let display = snapshot.display else { throw SpacesAdapterError.noActiveDisplay }
        return DisplayTopologySnapshot(
            displaysHaveSeparateSpaces: true,
            automaticallyRearrangesSpaces: false,
            sections: [DisplayDesktopSectionSnapshot(
                primaryDisplay: display,
                memberDisplays: [display],
                isMain: true,
                bounds: DisplayBounds(x: 0, y: 0, width: 0, height: 0),
                orderedDesktopUUIDs: snapshot.orderedDesktopUUIDs
            )]
        )
    }

    /// Compatibility defaults keep focused test doubles small. Production uses
    /// `MacOSSpacesAdapter`'s topology-aware implementations.
    func availableDisplays() throws -> [DisplayIdentity] {
        if let display = try currentDesktopSnapshot().display { return [display] }
        return []
    }

    func desktopSnapshot(for display: DisplayIdentity) throws -> DesktopSnapshot {
        let snapshot = try currentDesktopSnapshot()
        guard snapshot.display?.identifiesSameDisplay(as: display) != false else {
            throw SpacesAdapterError.noActiveDisplay
        }
        return DesktopSnapshot(display: display, orderedDesktopUUIDs: snapshot.orderedDesktopUUIDs)
    }

    func persistedDesktopUUIDs(
        for bundleIdentifiers: Set<String>
    ) throws -> [String: String] {
        [:]
    }

    func activeDesktopDestinations(
        in topology: DisplayTopologySnapshot
    ) throws -> Set<DesktopAddress> {
        guard let section = topology.sections.first,
              let number = try activeDesktopNumber()
        else { return [] }
        return [DesktopAddress(display: section.primaryDisplay, desktopNumber: number)]
    }

    func apply(plan: AssignmentApplyPlan, expectedTopology: DisplayTopologySnapshot) throws {
        try apply(
            managedBindings: plan.updates,
            managedBundleIdentifiers: Set(plan.updates.keys).union(plan.deletions),
            expectedSnapshot: nil
        )
    }
}

/// Runs an external command, returning its standard output.
///
/// Injectable so tests can exercise `MacOSSpacesAdapter` without touching the
/// real `defaults` store or restarting the Dock.
public protocol CommandRunning {
    func run(executable: String, arguments: [String]) throws -> Data
}

/// Updates WindowServer's current-session application bindings through the
/// dynamically resolved private SkyLight setter.
///
/// `preflight()` verifies the private symbols are resolvable *before* Apply
/// mutates any persistent state, so an unavailable ABI fails closed without
/// leaving a partial managed update or altering unmanaged bindings.
public protocol SessionBindingUpdating {
    func preflight() throws
    func update(appBindings: [String: String]) throws
}

public final class MacOSSpacesAdapter: SpacesAdapter {
    private let commandRunner: CommandRunning
    private let sessionBindingUpdater: SessionBindingUpdating
    private let displayInventory: DisplayInventoryProviding
    private let activeSpaceProvider: ActiveSpaceProviding
    private let activeDisplaySpacesProvider: ActiveDisplaySpacesProviding
    private let displaySettings: DisplaySettingsProviding

    public init(
        commandRunner: CommandRunning? = nil,
        sessionBindingUpdater: SessionBindingUpdating? = nil,
        displayInventory: DisplayInventoryProviding? = nil,
        activeSpaceProvider: ActiveSpaceProviding? = nil,
        activeDisplaySpacesProvider: ActiveDisplaySpacesProviding? = nil,
        displaySettings: DisplaySettingsProviding? = nil
    ) {
        self.commandRunner = commandRunner ?? CommandRunner()
        self.sessionBindingUpdater = sessionBindingUpdater ?? SessionBindingUpdater()
        self.displayInventory = displayInventory ?? CoreGraphicsDisplayInventory()
        self.activeSpaceProvider = activeSpaceProvider ?? SkyLightActiveSpaceProvider()
        self.activeDisplaySpacesProvider = activeDisplaySpacesProvider
            ?? SkyLightActiveDisplaySpacesProvider()
        self.displaySettings = displaySettings ?? SystemDisplaySettingsProvider()
    }

    public func currentDisplayTopology() throws -> DisplayTopologySnapshot {
        try DisplayResolution.topology(
            from: displayInventory.activeDisplays(),
            store: readStore(),
            displaysHaveSeparateSpaces: displaySettings.displaysHaveSeparateSpaces,
            automaticallyRearrangesSpaces: displaySettings.automaticallyRearrangesSpaces
        )
    }

    public func currentDesktopSnapshot() throws -> DesktopSnapshot {
        // Resolve the sole active logical Display — built-in, external with the
        // lid closed, or a mirrored group — to the private "Main" monitor key,
        // then read that monitor's live Desktops. Zero or multiple extended
        // Displays throw before any store read, leaving macOS untouched.
        let displays = DisplayResolution.logicalDisplays(from: try displayInventory.activeDisplays())
        guard let display = displays.first else { throw SpacesAdapterError.noActiveDisplay }
        guard displays.count == 1 else { throw SpacesAdapterError.multipleDisplaysUnsupported }
        guard display.isMain else { throw SpacesAdapterError.noActiveDisplay }
        guard let identity = display.identity else {
            throw SpacesAdapterError.displayEnumerationFailed
        }
        return try resolvedDesktopSnapshot(for: display, identity: identity)
    }

    public func availableDisplays() throws -> [DisplayIdentity] {
        let displays = DisplayResolution.logicalDisplays(from: try displayInventory.activeDisplays())
        guard !displays.isEmpty else { throw SpacesAdapterError.noActiveDisplay }
        let identities = displays.compactMap(\.identity)
        guard identities.count == displays.count else {
            throw SpacesAdapterError.displayEnumerationFailed
        }
        return identities
    }

    public func desktopSnapshot(for display: DisplayIdentity) throws -> DesktopSnapshot {
        let active = try DisplayResolution.activeDisplay(
            matching: display,
            in: displayInventory.activeDisplays()
        )
        guard let currentIdentity = active.identity else {
            throw SpacesAdapterError.displayEnumerationFailed
        }
        return try resolvedDesktopSnapshot(for: active, identity: currentIdentity)
    }

    public func persistedDesktopUUIDs(
        for bundleIdentifiers: Set<String>
    ) throws -> [String: String] {
        let stored = try readAppBindings()
        return Dictionary(
            uniqueKeysWithValues: bundleIdentifiers.compactMap { bundleIdentifier in
                guard let uuid = stored[bundleIdentifier.lowercased()] else { return nil }
                return (bundleIdentifier, uuid)
            }
        )
    }

    public func activeDesktopNumber() throws -> Int? {
        // Resolve the sole active logical Display exactly as the snapshot does,
        // then map the LIVE active managed Space ID read from WindowServer to its
        // position in that Display's ordered Desktops. Reading the live Space
        // rather than the exported store's `Current Space` (which can lag behind
        // the session) is the crux of issue #61. A topology that is not a single
        // main Display throws here (as in `currentDesktopSnapshot()`), so Arrange
        // never guesses against an ambiguous setup; an unreadable live Space or
        // one absent from the ordered Desktops resolves to `nil` so Arrange fails
        // closed rather than treating a wrong Desktop as active.
        let displayKey = try DisplayResolution.activeDisplayKey(
            for: displayInventory.activeDisplays()
        )
        guard let activeManagedSpaceID = try activeSpaceProvider.activeManagedSpaceID() else {
            return nil
        }
        let store = try readStore()
        return DisplayResolution.desktopNumber(
            forManagedSpaceID: activeManagedSpaceID,
            fromStore: store,
            displayKey: displayKey
        )
    }

    public func activeDesktopDestinations(
        in topology: DisplayTopologySnapshot
    ) throws -> Set<DesktopAddress> {
        let activeIDs = try activeDisplaySpacesProvider.activeManagedSpaceIDsByDisplayKey()
        let store = try readStore()
        var destinations: Set<DesktopAddress> = []
        for section in topology.sections {
            let key = section.isMain ? "Main" : section.primaryDisplay.colorSyncUUID
            let managedID = activeIDs[key]
                ?? (section.isMain ? activeIDs[section.primaryDisplay.colorSyncUUID] : nil)
            guard
                let managedID,
                let number = DisplayResolution.desktopNumber(
                    forManagedSpaceID: managedID,
                    fromStore: store,
                    displayKey: key
                )
            else { throw SpacesAdapterError.activeDesktopUnavailable }
            destinations.insert(
                DesktopAddress(display: section.primaryDisplay, desktopNumber: number)
            )
        }
        guard destinations.count == topology.sections.count else {
            throw SpacesAdapterError.activeDesktopUnavailable
        }
        return destinations
    }

    public func apply(
        managedBindings: [String: String],
        managedBundleIdentifiers: Set<String>,
        expectedSnapshot: DesktopSnapshot? = nil
    ) throws {
        // Preflight the private session-binding ABI before touching any
        // persistent state. If the symbols are unavailable, Apply fails closed
        // here, leaving both managed and unmanaged persistent bindings untouched
        // and the Dock un-restarted (issue #8, AC 4).
        try sessionBindingUpdater.preflight()

        // Normalize to the lowercase form macOS/Dock use. Ownership is decided on
        // the same normalized keys the store holds, so managed keys can be
        // deleted without disturbing unmanaged entries.
        let desiredManaged = Dictionary(
            managedBindings.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let managedOwnedKeys = Set(managedBundleIdentifiers.map { $0.lowercased() })

        // Read the existing store and compute the complete post-change
        // dictionary: unmanaged entries preserved, managed Assignments
        // added/changed, removed-managed keys deleted (issue #7 / ADR-0001).
        let existingBindings = try readAppBindings()
        let completeBindings = PersistentBindingReconciler.completeBindings(
            existing: existingBindings,
            desiredManaged: desiredManaged,
            managedOwnedKeys: managedOwnedKeys
        )

        // Revalidate the active Display, main role, and ordered Desktop snapshot
        // immediately before the first mutation. `managedBindings` was resolved
        // against `expectedSnapshot`; a fresh read that no longer matches means
        // the topology changed underneath (a lid transition, hot-plug, or
        // main-display change), so abort with no write and no Dock restart
        // rather than persisting bindings against a stale Desktop order
        // (issue #18, AC 8). A change that makes the setup unresolvable — a
        // second Display appearing or the last Display leaving — throws from
        // `currentDesktopSnapshot()` itself, aborting just as fail-closed before
        // any mutation.
        if let expectedSnapshot {
            guard try currentDesktopSnapshot() == expectedSnapshot else {
                throw SpacesAdapterError.displayTopologyChanged
            }
        }

        try writeAndActivate(completeBindings: completeBindings)
    }

    public func apply(
        plan: AssignmentApplyPlan,
        expectedTopology: DisplayTopologySnapshot
    ) throws {
        try sessionBindingUpdater.preflight()

        let updates = Dictionary(
            plan.updates.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let deletions = Set(plan.deletions.map { $0.lowercased() })
        let existing = try readAppBindings()
        let complete = PersistentBindingReconciler.completeBindings(
            existing: existing,
            updates: updates,
            deletions: deletions
        )

        guard expectedTopology.displaysHaveSeparateSpaces else {
            throw SpacesAdapterError.separateSpacesRequired
        }
        guard try currentDisplayTopology() == expectedTopology else {
            throw SpacesAdapterError.displayTopologyChanged
        }
        try writeAndActivate(completeBindings: complete)
    }

    private func writeAndActivate(completeBindings: [String: String]) throws {
        _ = try? commandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["delete", "com.apple.spaces", "app-bindings"]
        )
        for bundleIdentifier in completeBindings.keys.sorted() {
            guard let desktopUUID = completeBindings[bundleIdentifier] else { continue }
            _ = try commandRunner.run(
                executable: "/usr/bin/defaults",
                arguments: [
                    "write", "com.apple.spaces", "app-bindings", "-dict-add",
                    bundleIdentifier, desktopUUID,
                ]
            )
        }
        _ = try commandRunner.run(executable: "/usr/bin/killall", arguments: ["Dock"])
        let written = try readAppBindings()
        guard written == completeBindings else {
            let keys = Set(written.keys).union(completeBindings.keys)
            throw SpacesAdapterError.verificationFailed(
                bundleIdentifiers: keys.filter { written[$0] != completeBindings[$0] }.sorted()
            )
        }
        try sessionBindingUpdater.update(appBindings: written)
    }

    /// The current `app-bindings` dictionary, keeping only its string values.
    private func readAppBindings() throws -> [String: String] {
        let store = try readStore()
        let bindings = store["app-bindings"] as? [String: Any] ?? [:]
        return bindings.compactMapValues { $0 as? String }
    }

    private func readStore() throws -> [String: Any] {
        let data = try commandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["export", "com.apple.spaces", "-"]
        )
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let store = propertyList as? [String: Any] else {
            throw SpacesAdapterError.storeFormatChanged
        }
        return store
    }

    private func resolvedDesktopSnapshot(
        for display: ActiveDisplay,
        identity: DisplayIdentity
    ) throws -> DesktopSnapshot {
        let displayKey = try DisplayResolution.displayKey(for: display)
        let orderedDesktopUUIDs = try DisplayResolution.orderedDesktopUUIDs(
            fromStore: readStore(),
            displayKey: displayKey
        )
        return DesktopSnapshot(display: identity, orderedDesktopUUIDs: orderedDesktopUUIDs)
    }
}

public enum SpacesAdapterError: LocalizedError, Equatable {
    case commandFailed(executable: String, status: Int32, message: String)
    case activeDesktopUnavailable
    case displayEnumerationFailed
    case displayTopologyChanged
    case multipleDisplaysUnsupported
    case noActiveDisplay
    case noDesktopsFound
    case separateSpacesRequired
    case sessionBindingAPIUnavailable
    case storeFormatChanged
    case verificationFailed(bundleIdentifiers: [String])

    public var errorDescription: String? {
        switch self {
        case .activeDesktopUnavailable:
            "The currently visible Desktop could not be resolved for every Display."
        case let .commandFailed(executable, status, message):
            "\(executable) failed with status \(status): \(message)"
        case .displayEnumerationFailed:
            "The active displays could not be read."
        case .displayTopologyChanged:
            "The displays changed while applying. Nothing was written — review the board and try again."
        case .multipleDisplaysUnsupported:
            "Multiple displays are not yet supported. Use a single active display."
        case .noActiveDisplay:
            "No active display was found."
        case .noDesktopsFound:
            "No Desktops were found on the active display."
        case .separateSpacesRequired:
            "Displays have separate Spaces must be enabled to Apply or Arrange. Nothing was changed."
        case .sessionBindingAPIUnavailable:
            "The macOS Desktop session binding API is unavailable."
        case .storeFormatChanged:
            "The macOS Desktop store has an unrecognized format."
        case let .verificationFailed(bundleIdentifiers):
            "Apply could not verify the Assignment for \(bundleIdentifiers.joined(separator: ", "))."
        }
    }
}

private typealias MainConnectionFunction = @convention(c) () -> Int32
private typealias SetSessionBindingsFunction = @convention(c) (
    Int32,
    CFDictionary
) -> Void

/// Resolves the private SkyLight session-binding symbols and applies the
/// current-session update. Resolution happens in `preflight()` so callers can
/// verify availability before mutating persistent state.
private final class SessionBindingUpdater: SessionBindingUpdating {
    private struct Resolved {
        let mainConnection: MainConnectionFunction
        let setSessionBindings: SetSessionBindingsFunction
    }

    private var resolved: Resolved?

    // On macOS 26, app-bindings persists Assignments but does not update the
    // WindowServer session. Dock's Assign To action calls this private setter.
    func preflight() throws {
        _ = try resolve()
    }

    func update(appBindings: [String: String]) throws {
        let resolved = try resolve()
        resolved.setSessionBindings(
            resolved.mainConnection(),
            appBindings as CFDictionary
        )
    }

    private func resolve() throws -> Resolved {
        if let resolved {
            return resolved
        }

        // The handle is intentionally left open for the adapter's lifetime: the
        // resolved function pointers must stay valid for a later update().
        guard let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            throw SpacesAdapterError.sessionBindingAPIUnavailable
        }

        guard
            let mainConnectionSymbol = dlsym(skyLight, "SLSMainConnectionID")
                ?? dlsym(skyLight, "CGSMainConnectionID"),
            let setterSymbol = dlsym(
                skyLight,
                "SLSSessionSetCurrentSessionWorkspaceApplicationBindings"
            ) ?? dlsym(
                skyLight,
                "CGSSessionSetCurrentSessionWorkspaceApplicationBindings"
            )
        else {
            dlclose(skyLight)
            throw SpacesAdapterError.sessionBindingAPIUnavailable
        }

        let resolved = Resolved(
            mainConnection: unsafeBitCast(
                mainConnectionSymbol,
                to: MainConnectionFunction.self
            ),
            setSessionBindings: unsafeBitCast(
                setterSymbol,
                to: SetSessionBindingsFunction.self
            )
        )
        self.resolved = resolved
        return resolved
    }
}

private struct CommandRunner: CommandRunning {
    func run(executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw SpacesAdapterError.commandFailed(
                executable: executable,
                status: process.terminationStatus,
                message: message
            )
        }

        return outputData
    }
}
