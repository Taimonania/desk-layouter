import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

// Verifies single-active-Display resolution (issue #18): which logical Display
// is active across built-in-only, external-only, mirrored, zero, and multiple
// topologies; which ordered Desktops that Display hosts (including live-Main
// resolution amid collapsed history and empty-string Desktop UUIDs); and that
// Apply revalidates the topology immediately before the first mutation, aborting
// with no write and no Dock restart on a race. Hand-rolled @main runner style,
// no XCTest, no real hardware — the display inventory and `defaults` store are
// injected seams.

/// A display inventory whose returned topology is fully controlled by the test.
final class StubDisplayInventory: DisplayInventoryProviding {
    var displays: [ActiveDisplay]
    var error: Error?

    init(displays: [ActiveDisplay] = [], error: Error? = nil) {
        self.displays = displays
        self.error = error
    }

    func activeDisplays() throws -> [ActiveDisplay] {
        if let error { throw error }
        return displays
    }
}

/// Models the exported `com.apple.spaces` store — a "Main" monitor with the
/// given ordered Desktop UUIDs plus optional collapsed history — and the
/// `app-bindings` mutation path, so a full Apply can be exercised without the
/// real `defaults` tool. The live Desktop order can be swapped mid-run to model
/// a topology race between planning and Apply.
final class StoreCommandRunner: CommandRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    var mainDesktopUUIDs: [String]
    var includeCollapsedDuplicate: Bool
    private(set) var appBindings: [String: String]

    init(
        mainDesktopUUIDs: [String],
        includeCollapsedDuplicate: Bool = false,
        appBindings: [String: String] = [:]
    ) {
        self.mainDesktopUUIDs = mainDesktopUUIDs
        self.includeCollapsedDuplicate = includeCollapsedDuplicate
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

    private func storeDictionary() -> [String: Any] {
        var monitors: [[String: Any]] = []
        // A collapsed/historical monitor keyed "Main" with only `Collapsed
        // Space` — must be skipped in favor of the live one that has `Spaces`.
        if includeCollapsedDuplicate {
            monitors.append([
                "Display Identifier": "Main",
                "Collapsed Space": ["uuid": "COLLAPSED"],
            ])
        }
        let spaces: [[String: Any]] = mainDesktopUUIDs.map { ["uuid": $0] }
            + [["uuid": "TILE", "TileLayoutManager": ["ignored": true]]]
        monitors.append([
            "Display Identifier": "Main",
            "Spaces": spaces,
        ])
        return [
            "app-bindings": appBindings,
            "SpacesDisplayConfiguration": [
                "Management Data": ["Monitors": monitors],
            ],
        ]
    }

    func run(executable: String, arguments: [String]) throws -> Data {
        calls.append((executable, arguments))
        guard executable == "/usr/bin/defaults" else { return Data() }
        switch arguments.first {
        case "export":
            return try PropertyListSerialization.data(
                fromPropertyList: storeDictionary(),
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

/// A session-binding updater that records whether it was asked to apply.
final class StubSessionUpdater: SessionBindingUpdating {
    private(set) var preflightCallCount = 0
    private(set) var updatedBindings: [[String: String]] = []

    func preflight() throws { preflightCallCount += 1 }
    func update(appBindings: [String: String]) throws { updatedBindings.append(appBindings) }
}

func display(id: UInt32, main: Bool = false, mirrors: UInt32 = 0) -> ActiveDisplay {
    ActiveDisplay(displayID: id, isMain: main, mirrorsDisplayID: mirrors)
}

@main
struct DisplayTestRunner {
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

        func expectError(_ name: String, _ expected: SpacesAdapterError, _ body: () throws -> Void) {
            do {
                try body()
                check(name, false, "did not throw")
            } catch {
                check(name, (error as? SpacesAdapterError) == expected, "got \(error)")
            }
        }

        // MARK: - activeDisplayKey topologies.

        check(
            "one built-in main Display resolves to the Main store key",
            (try? DisplayResolution.activeDisplayKey(for: [display(id: 1, main: true)])) == "Main"
        )
        check(
            "one external main Display (lid closed) resolves to the Main store key",
            (try? DisplayResolution.activeDisplayKey(for: [display(id: 3, main: true)])) == "Main"
        )
        expectError("a sole non-main Display is not resolvable", .noActiveDisplay) {
            _ = try DisplayResolution.activeDisplayKey(for: [display(id: 3, main: false)])
        }
        check(
            "a mirror set collapses to one logical Display and resolves to Main",
            (try? DisplayResolution.activeDisplayKey(for: [
                display(id: 1, main: true),
                display(id: 3, mirrors: 1),
            ])) == "Main"
        )
        expectError("zero active Displays reports noActiveDisplay", .noActiveDisplay) {
            _ = try DisplayResolution.activeDisplayKey(for: [])
        }
        expectError("two extended Displays report multipleDisplaysUnsupported", .multipleDisplaysUnsupported) {
            _ = try DisplayResolution.activeDisplayKey(for: [
                display(id: 1, main: true),
                display(id: 3),
            ])
        }

        // MARK: - Store resolution.

        do {
            let store: [String: Any] = [
                "SpacesDisplayConfiguration": [
                    "Management Data": [
                        "Monitors": [
                            // Collapsed history keyed "Main" — must be ignored.
                            ["Display Identifier": "Main", "Collapsed Space": ["uuid": "OLD"]],
                            [
                                "Display Identifier": "Main",
                                "Spaces": [
                                    ["uuid": ""],
                                    ["uuid": "B4DE213"],
                                    ["uuid": "TILE", "TileLayoutManager": ["x": 1]],
                                ],
                            ],
                        ],
                    ],
                ],
            ]
            let resolved = try? DisplayResolution.orderedDesktopUUIDs(fromStore: store, displayKey: "Main")
            check(
                "live Main monitor wins over a collapsed entry, tiles filtered, empty UUID kept",
                resolved == ["", "B4DE213"],
                "got \(String(describing: resolved))"
            )
        }

        expectError("a monitor with no Spaces array reports storeFormatChanged", .storeFormatChanged) {
            let store: [String: Any] = [
                "SpacesDisplayConfiguration": [
                    "Management Data": [
                        "Monitors": [["Display Identifier": "Main", "Collapsed Space": ["uuid": "OLD"]]],
                    ],
                ],
            ]
            _ = try DisplayResolution.orderedDesktopUUIDs(fromStore: store, displayKey: "Main")
        }

        // MARK: - currentDesktopSnapshot end-to-end (external-only topology).

        do {
            let inventory = StubDisplayInventory(displays: [display(id: 3, main: true)])
            let runner = StoreCommandRunner(mainDesktopUUIDs: ["", "D2", "D3"], includeCollapsedDuplicate: true)
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: StubSessionUpdater(),
                displayInventory: inventory
            )
            let snapshot = try? adapter.currentDesktopSnapshot()
            check(
                "external-only snapshot loads the Main monitor's Desktops in positional order",
                snapshot?.orderedDesktopUUIDs == ["", "D2", "D3"],
                "got \(String(describing: snapshot))"
            )
        }

        expectError("snapshot with multiple Displays fails without mutation", .multipleDisplaysUnsupported) {
            let inventory = StubDisplayInventory(displays: [
                display(id: 1, main: true),
                display(id: 3),
            ])
            let runner = StoreCommandRunner(mainDesktopUUIDs: ["A"])
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: StubSessionUpdater(),
                displayInventory: inventory
            )
            defer {
                check("multiple-Display snapshot issues no command", runner.calls.isEmpty)
            }
            _ = try adapter.currentDesktopSnapshot()
        }

        // MARK: - Apply revalidation: topology race aborts with no mutation.

        do {
            let inventory = StubDisplayInventory(displays: [display(id: 3, main: true)])
            let runner = StoreCommandRunner(mainDesktopUUIDs: ["D1", "D2", "D3"])
            let updater = StubSessionUpdater()
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: updater,
                displayInventory: inventory
            )
            // The board was planned against a two-Desktop order; the live store
            // now reports three — a topology change between planning and Apply.
            let staleSnapshot = DesktopSnapshot(orderedDesktopUUIDs: ["D1", "D2"])

            var thrown: Error?
            do {
                try adapter.apply(
                    managedBindings: ["com.example.app": "D2"],
                    managedBundleIdentifiers: ["com.example.app"],
                    expectedSnapshot: staleSnapshot
                )
            } catch {
                thrown = error
            }

            check(
                "Apply throws displayTopologyChanged on a race",
                (thrown as? SpacesAdapterError) == .displayTopologyChanged,
                "got \(String(describing: thrown))"
            )
            check("racing Apply performs no persistent write", runner.writeCalls.isEmpty && runner.deleteCalls.isEmpty)
            check("racing Apply does not restart the Dock", runner.killallCalls.isEmpty)
            check("racing Apply never updates the live session", updater.updatedBindings.isEmpty)
        }

        // MARK: - Apply revalidation: a second Display appearing aborts too.

        do {
            // A second extended Display appeared between planning and Apply, so
            // the pre-mutation revalidation can no longer resolve a single active
            // Display and must abort before any write.
            let inventory = StubDisplayInventory(displays: [
                display(id: 3, main: true),
                display(id: 4),
            ])
            let runner = StoreCommandRunner(mainDesktopUUIDs: ["D1", "D2", "D3"])
            let updater = StubSessionUpdater()
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: updater,
                displayInventory: inventory
            )
            let snapshot = DesktopSnapshot(orderedDesktopUUIDs: ["D1", "D2", "D3"])

            var thrown: Error?
            do {
                try adapter.apply(
                    managedBindings: ["com.example.app": "D2"],
                    managedBundleIdentifiers: ["com.example.app"],
                    expectedSnapshot: snapshot
                )
            } catch {
                thrown = error
            }

            check(
                "a second Display appearing aborts Apply with multipleDisplaysUnsupported",
                (thrown as? SpacesAdapterError) == .multipleDisplaysUnsupported,
                "got \(String(describing: thrown))"
            )
            check("second-Display race performs no persistent write", runner.writeCalls.isEmpty && runner.deleteCalls.isEmpty)
            check("second-Display race does not restart the Dock", runner.killallCalls.isEmpty)
            check("second-Display race never updates the live session", updater.updatedBindings.isEmpty)
        }

        // MARK: - Apply revalidation: unchanged topology proceeds.

        do {
            let inventory = StubDisplayInventory(displays: [display(id: 3, main: true)])
            let runner = StoreCommandRunner(mainDesktopUUIDs: ["D1", "D2", "D3"])
            let updater = StubSessionUpdater()
            let adapter = MacOSSpacesAdapter(
                commandRunner: runner,
                sessionBindingUpdater: updater,
                displayInventory: inventory
            )
            let snapshot = DesktopSnapshot(orderedDesktopUUIDs: ["D1", "D2", "D3"])

            var thrown: Error?
            do {
                try adapter.apply(
                    managedBindings: ["com.example.app": "D2"],
                    managedBundleIdentifiers: ["com.example.app"],
                    expectedSnapshot: snapshot
                )
            } catch {
                thrown = error
            }

            check("Apply with an unchanged topology succeeds", thrown == nil, "got \(String(describing: thrown))")
            check("unchanged-topology Apply persists the managed binding", runner.appBindings["com.example.app"] == "D2")
            check("unchanged-topology Apply restarts the Dock once", runner.killallCalls.count == 1)
        }

        if failures.isEmpty {
            print("Display-resolution tests passed")
        } else {
            fatalError("Display-resolution tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
