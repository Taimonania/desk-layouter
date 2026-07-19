import AppKit
import CoreGraphics
import Darwin
import Foundation

private enum ProbeError: Error, CustomStringConvertible {
    case builtInDisplayNotFound
    case displayEnumerationFailed
    case missingSymbol(String)
    case noSpaces(Int32)

    var description: String {
        switch self {
        case .builtInDisplayNotFound:
            "no active built-in display was found"
        case .displayEnumerationFailed:
            "active displays could not be read"
        case let .missingSymbol(symbol):
            "SkyLight symbol \(symbol) is unavailable"
        case let .noSpaces(windowNumber):
            "window \(windowNumber) has no managed Space"
        }
    }
}

private func builtInDisplayIdentifier() throws -> String {
    var displayCount: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
        throw ProbeError.displayEnumerationFailed
    }

    var displayIdentifiers = Array(
        repeating: CGDirectDisplayID(),
        count: Int(displayCount)
    )
    guard
        CGGetActiveDisplayList(displayCount, &displayIdentifiers, &displayCount) == .success,
        let builtInDisplay = displayIdentifiers.first(where: { CGDisplayIsBuiltin($0) != 0 })
    else {
        throw ProbeError.builtInDisplayNotFound
    }

    if builtInDisplay == CGMainDisplayID() {
        return "Main"
    }
    let displayUUID = CGDisplayCreateUUIDFromDisplayID(builtInDisplay).takeRetainedValue()
    return CFUUIDCreateString(nil, displayUUID) as String
}

private typealias MainConnection = @convention(c) () -> Int32
private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
private typealias SetSessionBindings = @convention(c) (
    Int32,
    CFDictionary
) -> Void
private typealias CopySpaces = @convention(c) (
    Int32,
    Int32,
    CFArray
) -> Unmanaged<CFArray>?

private func loadSymbol<T>(
    _ names: [String],
    from handle: UnsafeMutableRawPointer,
    as _: T.Type
) throws -> T {
    for name in names {
        if let symbol = dlsym(handle, name) {
            return unsafeBitCast(symbol, to: T.self)
        }
    }
    throw ProbeError.missingSymbol(names.joined(separator: " or "))
}

private final class SkyLightHandle {
    let pointer: UnsafeMutableRawPointer
    let mainConnection: MainConnection

    init() throws {
        guard let pointer = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            throw ProbeError.missingSymbol("SkyLight.framework")
        }
        self.pointer = pointer
        mainConnection = try loadSymbol(
            ["SLSMainConnectionID", "CGSMainConnectionID"],
            from: pointer,
            as: MainConnection.self
        )
    }

    deinit {
        dlclose(pointer)
    }
}

private func inspect(processIdentifier: Int32, windowNumber: NSNumber) throws {
    let skyLight = try SkyLightHandle()
    let copySpaces = try loadSymbol(
        ["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"],
        from: skyLight.pointer,
        as: CopySpaces.self
    )

    guard let spaces = copySpaces(
        skyLight.mainConnection(),
        0x7,
        [windowNumber] as CFArray
    )?.takeRetainedValue() as? [NSNumber], !spaces.isEmpty else {
        throw ProbeError.noSpaces(windowNumber.int32Value)
    }
    let observations: [[String: Any]] = [[
        "window": windowNumber,
        "process": processIdentifier,
        "managedSpaceIDs": spaces,
    ]]

    let data = try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func printActiveSpace() throws {
    let skyLight = try SkyLightHandle()
    let activeSpace = try loadSymbol(
        ["SLSGetActiveSpace", "CGSGetActiveSpace"],
        from: skyLight.pointer,
        as: ActiveSpace.self
    )
    print(activeSpace(skyLight.mainConnection()))
}

private func setSessionBindings(from fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    let bindings: [String: String]
    if data.isEmpty {
        bindings = [:]
    } else {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        bindings = decoded
    }

    let skyLight = try SkyLightHandle()
    let setter = try loadSymbol(
        [
            "SLSSessionSetCurrentSessionWorkspaceApplicationBindings",
            "CGSSessionSetCurrentSessionWorkspaceApplicationBindings",
        ],
        from: skyLight.pointer,
        as: SetSessionBindings.self
    )
    setter(skyLight.mainConnection(), bindings as CFDictionary)
}

private final class ProbeApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 480, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Desk Layouter Desktop Placement Probe"
        window.contentView = NSTextField(labelWithString: "Disposable placement probe")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        if
            let argumentIndex = CommandLine.arguments.firstIndex(of: "--window-number-file"),
            CommandLine.arguments.indices.contains(argumentIndex + 1)
        {
            let outputURL = URL(fileURLWithPath: CommandLine.arguments[argumentIndex + 1])
            try? String(window.windowNumber).write(to: outputURL, atomically: true, encoding: .utf8)
        }

        // A final safety net if the launching process is interrupted before its trap runs.
        Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { _ in
            NSApplication.shared.terminate(nil)
        }
    }
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--built-in-display-identifier" {
    do {
        print(try builtInDisplayIdentifier())
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--active-space" {
    do {
        try printActiveSpace()
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--set-session-bindings" {
    do {
        try setSessionBindings(from: URL(fileURLWithPath: CommandLine.arguments[2]))
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--inspect" {
    guard
        let processIdentifier = Int32(CommandLine.arguments[2]),
        let windowNumber = Int32(CommandLine.arguments[3])
    else {
        fputs("invalid process or window identifier\n", stderr)
        exit(2)
    }
    do {
        try inspect(processIdentifier: processIdentifier, windowNumber: NSNumber(value: windowNumber))
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
} else {
    let application = NSApplication.shared
    let delegate = ProbeApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
