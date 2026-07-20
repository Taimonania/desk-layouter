import Darwin
import DeskLayouterCore
import Foundation

public protocol SpacesAdapter {
    func currentDesktopSnapshot() throws -> DesktopSnapshot

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

    public init(
        commandRunner: CommandRunning? = nil,
        sessionBindingUpdater: SessionBindingUpdating? = nil,
        displayInventory: DisplayInventoryProviding? = nil
    ) {
        self.commandRunner = commandRunner ?? CommandRunner()
        self.sessionBindingUpdater = sessionBindingUpdater ?? SessionBindingUpdater()
        self.displayInventory = displayInventory ?? CoreGraphicsDisplayInventory()
    }

    public func currentDesktopSnapshot() throws -> DesktopSnapshot {
        // Resolve the sole active logical Display — built-in, external with the
        // lid closed, or a mirrored group — to the private "Main" monitor key,
        // then read that monitor's live Desktops. Zero or multiple extended
        // Displays throw before any store read, leaving macOS untouched.
        let displayKey = try DisplayResolution.activeDisplayKey(
            for: displayInventory.activeDisplays()
        )
        let store = try readStore()
        let orderedDesktopUUIDs = try DisplayResolution.orderedDesktopUUIDs(
            fromStore: store,
            displayKey: displayKey
        )
        return DesktopSnapshot(orderedDesktopUUIDs: orderedDesktopUUIDs)
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

        // Rewrite the whole dictionary. A plain `-dict-add` can only add or
        // replace keys, so the existing dictionary is cleared first and then the
        // complete dictionary is written back — this is what lets a removed
        // managed key actually disappear from the persistent store.
        _ = try? commandRunner.run(
            executable: "/usr/bin/defaults",
            arguments: ["delete", "com.apple.spaces", "app-bindings"]
        )
        for bundleIdentifier in completeBindings.keys.sorted() {
            guard let desktopUUID = completeBindings[bundleIdentifier] else {
                continue
            }
            _ = try commandRunner.run(
                executable: "/usr/bin/defaults",
                arguments: [
                    "write",
                    "com.apple.spaces",
                    "app-bindings",
                    "-dict-add",
                    bundleIdentifier,
                    desktopUUID,
                ]
            )
        }

        _ = try commandRunner.run(
            executable: "/usr/bin/killall",
            arguments: ["Dock"]
        )

        // Persistent read-back verification: the store must now match the
        // complete dictionary exactly — every managed change present, every
        // removed-managed key gone, every unmanaged entry intact.
        let writtenBindings = try readAppBindings()
        guard writtenBindings == completeBindings else {
            let allKeys = Set(writtenBindings.keys).union(completeBindings.keys)
            let mismatched = allKeys
                .filter { writtenBindings[$0] != completeBindings[$0] }
                .sorted()
            throw SpacesAdapterError.verificationFailed(bundleIdentifiers: mismatched)
        }

        // Live session update with the complete persisted dictionary, so removed
        // and changed Assignments take effect in the current session too.
        try sessionBindingUpdater.update(appBindings: writtenBindings)
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
}

public enum SpacesAdapterError: LocalizedError, Equatable {
    case commandFailed(executable: String, status: Int32, message: String)
    case displayEnumerationFailed
    case displayTopologyChanged
    case multipleDisplaysUnsupported
    case noActiveDisplay
    case noDesktopsFound
    case sessionBindingAPIUnavailable
    case storeFormatChanged
    case verificationFailed(bundleIdentifiers: [String])

    public var errorDescription: String? {
        switch self {
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
