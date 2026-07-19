import DeskLayouterMacOS
import Foundation

// Verifies MacOSSpacesAdapter's fail-closed behavior when the private
// session-binding ABI is unavailable (issue #8, AC 4), plus the happy-path
// ordering guarantee that Apply only mutates persistent state after a
// successful preflight. Uses injected seams instead of touching the real
// `defaults` store, Dock, or SkyLight — no XCTest, matching the repo's
// hand-rolled @main runner style.

/// Records every command issued and models the `com.apple.spaces` `app-bindings`
/// store well enough to serve read-backs, so a successful Apply can be exercised
/// without the real `defaults` tool.
final class RecordingCommandRunner: CommandRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    private(set) var appBindings: [String: String]

    init(appBindings: [String: String] = [:]) {
        self.appBindings = appBindings
    }

    var writeCalls: [(executable: String, arguments: [String])] {
        calls.filter { $0.executable == "/usr/bin/defaults" && $0.arguments.first == "write" }
    }

    var deleteCalls: [(executable: String, arguments: [String])] {
        calls.filter { $0.executable == "/usr/bin/defaults" && $0.arguments.first == "delete" }
    }

    var killallCalls: [(executable: String, arguments: [String])] {
        calls.filter { $0.executable == "/usr/bin/killall" }
    }

    func run(executable: String, arguments: [String]) throws -> Data {
        calls.append((executable, arguments))
        guard executable == "/usr/bin/defaults" else {
            return Data()
        }
        switch arguments.first {
        case "export":
            let store: [String: Any] = ["app-bindings": appBindings]
            return try PropertyListSerialization.data(
                fromPropertyList: store,
                format: .xml,
                options: 0
            )
        case "delete":
            if arguments.count >= 3, arguments[2] == "app-bindings" {
                appBindings = [:]
            }
            return Data()
        case "write":
            if arguments.count == 6, arguments[3] == "-dict-add" {
                appBindings[arguments[4]] = arguments[5]
            }
            return Data()
        default:
            return Data()
        }
    }
}

/// A session-binding updater whose availability and recorded calls are fully
/// controlled by the test.
final class StubSessionUpdater: SessionBindingUpdating {
    private let preflightError: Error?
    private(set) var preflightCallCount = 0
    private(set) var updatedBindings: [[String: String]] = []
    var onPreflight: (() -> Void)?

    init(preflightError: Error? = nil) {
        self.preflightError = preflightError
    }

    func preflight() throws {
        preflightCallCount += 1
        onPreflight?()
        if let preflightError {
            throw preflightError
        }
    }

    func update(appBindings: [String: String]) throws {
        updatedBindings.append(appBindings)
    }
}

@main
struct AdapterFailureTestRunner {
    static func main() {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let detailText = detail()
                let suffix = detailText.isEmpty ? "" : " — \(detailText)"
                failures.append("\(name)\(suffix)")
                print("  FAIL: \(name)\(suffix)")
            }
        }

        // MARK: Unavailable private symbols must fail closed with no mutation.

        do {
            let commandRunner = RecordingCommandRunner(
                appBindings: ["com.other.unmanaged": "UNMANAGED-UUID"]
            )
            var commandCountAtPreflight = -1
            let updater = StubSessionUpdater(
                preflightError: SpacesAdapterError.sessionBindingAPIUnavailable
            )
            updater.onPreflight = { commandCountAtPreflight = commandRunner.calls.count }

            let adapter = MacOSSpacesAdapter(
                commandRunner: commandRunner,
                sessionBindingUpdater: updater
            )

            var thrown: Error?
            do {
                try adapter.apply(
                    managedBindings: ["com.example.app": "TARGET-UUID"],
                    managedBundleIdentifiers: ["com.example.app"]
                )
            } catch {
                thrown = error
            }

            check(
                "Apply throws the clear sessionBindingAPIUnavailable error",
                (thrown as? SpacesAdapterError) == .sessionBindingAPIUnavailable,
                "got \(String(describing: thrown))"
            )
            check(
                "preflight runs before any command is issued",
                commandCountAtPreflight == 0,
                "commands issued at preflight time: \(commandCountAtPreflight)"
            )
            check(
                "no command whatsoever is issued (no export/delete/write/killall)",
                commandRunner.calls.isEmpty,
                "issued: \(commandRunner.calls.map { ([$0.executable] + $0.arguments).joined(separator: " ") })"
            )
            check(
                "no persistent write occurs",
                commandRunner.writeCalls.isEmpty && commandRunner.deleteCalls.isEmpty
            )
            check("Dock is not restarted", commandRunner.killallCalls.isEmpty)
            check(
                "unmanaged binding is left exactly untouched",
                commandRunner.appBindings == ["com.other.unmanaged": "UNMANAGED-UUID"],
                "got \(commandRunner.appBindings)"
            )
            check(
                "the session updater is never asked to apply bindings",
                updater.updatedBindings.isEmpty
            )
        }

        // MARK: Available private symbols: Apply mutates only after preflight.

        do {
            let commandRunner = RecordingCommandRunner(
                appBindings: ["com.other.unmanaged": "UNMANAGED-UUID"]
            )
            let updater = StubSessionUpdater()
            let adapter = MacOSSpacesAdapter(
                commandRunner: commandRunner,
                sessionBindingUpdater: updater
            )

            var thrown: Error?
            do {
                try adapter.apply(
                    managedBindings: ["com.example.App": "TARGET-UUID"],
                    managedBundleIdentifiers: ["com.example.App"]
                )
            } catch {
                thrown = error
            }

            check("Apply succeeds when the ABI is available", thrown == nil, "got \(String(describing: thrown))")
            check("preflight is invoked exactly once", updater.preflightCallCount == 1)
            check("Dock is restarted exactly once", commandRunner.killallCalls.count == 1)
            check(
                "managed binding is persisted with the lowercased key",
                commandRunner.appBindings["com.example.app"] == "TARGET-UUID",
                "got \(commandRunner.appBindings)"
            )
            check(
                "unmanaged binding is preserved through Apply",
                commandRunner.appBindings["com.other.unmanaged"] == "UNMANAGED-UUID",
                "got \(commandRunner.appBindings)"
            )
            check(
                "the session updater receives the complete persisted dictionary",
                updater.updatedBindings == [[
                    "com.example.app": "TARGET-UUID",
                    "com.other.unmanaged": "UNMANAGED-UUID",
                ]],
                "got \(updater.updatedBindings)"
            )
        }

        if failures.isEmpty {
            print("Adapter failure-path tests passed")
        } else {
            fatalError("Adapter failure-path tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
