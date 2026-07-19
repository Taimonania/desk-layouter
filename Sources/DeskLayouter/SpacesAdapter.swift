import ColorSync
import CoreGraphics
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
    func apply(
        managedBindings: [String: String],
        managedBundleIdentifiers: Set<String>
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

    public init(
        commandRunner: CommandRunning? = nil,
        sessionBindingUpdater: SessionBindingUpdating? = nil
    ) {
        self.commandRunner = commandRunner ?? CommandRunner()
        self.sessionBindingUpdater = sessionBindingUpdater ?? SessionBindingUpdater()
    }

    public func currentDesktopSnapshot() throws -> DesktopSnapshot {
        let builtInDisplayIdentifier = try builtInDisplayIdentifier()
        let store = try readStore()
        guard
            let configuration = store["SpacesDisplayConfiguration"] as? [String: Any],
            let managementData = configuration["Management Data"] as? [String: Any],
            let monitors = managementData["Monitors"] as? [[String: Any]],
            let builtInMonitor = monitors.first(where: {
                $0["Display Identifier"] as? String == builtInDisplayIdentifier
                    && $0["Spaces"] != nil
            }),
            let desktopEntries = builtInMonitor["Spaces"] as? [[String: Any]]
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

        return DesktopSnapshot(orderedDesktopUUIDs: orderedDesktopUUIDs)
    }

    private func builtInDisplayIdentifier() throws -> String {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            throw SpacesAdapterError.displayEnumerationFailed
        }

        var displayIdentifiers = Array(
            repeating: CGDirectDisplayID(),
            count: Int(displayCount)
        )
        guard
            CGGetActiveDisplayList(displayCount, &displayIdentifiers, &displayCount) == .success,
            let builtInDisplay = displayIdentifiers.first(where: { CGDisplayIsBuiltin($0) != 0 })
        else {
            throw SpacesAdapterError.builtInDisplayNotFound
        }

        if builtInDisplay == CGMainDisplayID() {
            return "Main"
        }

        let displayUUID = CGDisplayCreateUUIDFromDisplayID(builtInDisplay).takeRetainedValue()
        return CFUUIDCreateString(nil, displayUUID) as String
    }

    public func apply(
        managedBindings: [String: String],
        managedBundleIdentifiers: Set<String>
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
    case builtInDisplayNotFound
    case commandFailed(executable: String, status: Int32, message: String)
    case displayEnumerationFailed
    case noDesktopsFound
    case sessionBindingAPIUnavailable
    case storeFormatChanged
    case verificationFailed(bundleIdentifiers: [String])

    public var errorDescription: String? {
        switch self {
        case .builtInDisplayNotFound:
            "No active built-in display was found."
        case let .commandFailed(executable, status, message):
            "\(executable) failed with status \(status): \(message)"
        case .displayEnumerationFailed:
            "The active displays could not be read."
        case .noDesktopsFound:
            "No Desktops were found on the built-in display."
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
