import ColorSync
import CoreGraphics
import Darwin
import DeskLayouterCore
import Foundation

public protocol SpacesAdapter {
    func currentDesktopSnapshot() throws -> DesktopSnapshot
    func apply(appBindings: [String: String]) throws
}

public final class MacOSSpacesAdapter: SpacesAdapter {
    private let commandRunner = CommandRunner()
    private let sessionBindingUpdater = SessionBindingUpdater()

    public init() {}

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

    public func apply(appBindings: [String: String]) throws {
        let normalizedBindings = Dictionary(
            appBindings.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )

        for bundleIdentifier in normalizedBindings.keys.sorted() {
            guard let desktopUUID = normalizedBindings[bundleIdentifier] else {
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

        let store = try readStore()
        let writtenBindings = store["app-bindings"] as? [String: Any] ?? [:]
        let missingBindings = normalizedBindings.filter { bundleIdentifier, desktopUUID in
            writtenBindings[bundleIdentifier] as? String != desktopUUID
        }

        guard missingBindings.isEmpty else {
            throw SpacesAdapterError.verificationFailed(bundleIdentifiers: missingBindings.keys.sorted())
        }

        let completeBindings = writtenBindings.compactMapValues { $0 as? String }
        try sessionBindingUpdater.update(appBindings: completeBindings)
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

enum SpacesAdapterError: LocalizedError {
    case builtInDisplayNotFound
    case commandFailed(executable: String, status: Int32, message: String)
    case displayEnumerationFailed
    case noDesktopsFound
    case sessionBindingAPIUnavailable
    case storeFormatChanged
    case verificationFailed(bundleIdentifiers: [String])

    var errorDescription: String? {
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

private struct SessionBindingUpdater {
    func update(appBindings: [String: String]) throws {
        // On macOS 26, app-bindings persists Assignments but does not update the
        // WindowServer session. Dock's Assign To action calls this private setter.
        guard let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            throw SpacesAdapterError.sessionBindingAPIUnavailable
        }
        defer { dlclose(skyLight) }

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
            throw SpacesAdapterError.sessionBindingAPIUnavailable
        }

        let mainConnection = unsafeBitCast(
            mainConnectionSymbol,
            to: MainConnectionFunction.self
        )
        let setSessionBindings = unsafeBitCast(
            setterSymbol,
            to: SetSessionBindingsFunction.self
        )
        setSessionBindings(mainConnection(), appBindings as CFDictionary)
    }
}

private struct CommandRunner {
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
