import CoreGraphics
import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

// Regression coverage for issue #61: the immediate Arrange action must target the
// LIVE active managed Space reported by WindowServer — not the exported
// `com.apple.spaces` store's potentially stale `Current Space` — and must scope a
// single pass to only the applications assigned to that resolved Desktop.
//
// The crux scenario is a stale-store mismatch: the live session is on managed
// Space ID 1 (Desktop 1) while the exported store still records `Current Space`
// as managed ID 3 (Desktop 3), with Layouts assigned across Desktops 1 and 3.
// The test proves the adapter resolves Desktop 1 (ignoring the stale store) and
// that only Desktop 1's applications are passed to and reported by the arranger.
//
// Hand-rolled @main runner, no XCTest — matching the other test targets. Every
// live seam (the private active-space read, the display inventory, the
// `defaults` store, and the Accessibility window moves) is an injected stub, so
// nothing here touches real hardware, WindowServer, or the trust database.

/// A display inventory whose topology is fully controlled by the test.
final class StubDisplayInventory: DisplayInventoryProviding {
    var displays: [ActiveDisplay]
    init(displays: [ActiveDisplay]) { self.displays = displays }
    func activeDisplays() throws -> [ActiveDisplay] { displays }
}

/// A session-binding updater the adapter never uses on the Arrange path; present
/// only to satisfy the adapter's dependency.
final class StubSessionUpdater: SessionBindingUpdating {
    func preflight() throws {}
    func update(appBindings: [String: String]) throws {}
}

/// A private active-space reader whose reported live managed Space ID (or "could
/// not read", modeled as `nil`) is controlled by the test — standing in for the
/// real SkyLight `SLSGetActiveSpace` read.
final class StubActiveSpaceProvider: ActiveSpaceProviding {
    var managedSpaceID: UInt64?
    init(managedSpaceID: UInt64?) { self.managedSpaceID = managedSpaceID }
    func activeManagedSpaceID() throws -> UInt64? { managedSpaceID }
}

/// Exports a `com.apple.spaces` store with a single "Main" monitor whose ordered
/// Desktops each carry a `ManagedSpaceID`, plus a (deliberately stale) `Current
/// Space` UUID, so the adapter's store-export path can be exercised without the
/// real `defaults` tool.
final class StoreCommandRunner: CommandRunning {
    let desktops: [(uuid: String, managedSpaceID: UInt64)]
    let currentSpaceUUID: String

    init(desktops: [(uuid: String, managedSpaceID: UInt64)], currentSpaceUUID: String) {
        self.desktops = desktops
        self.currentSpaceUUID = currentSpaceUUID
    }

    private func storeDictionary() -> [String: Any] {
        var spaces: [[String: Any]] = desktops.map {
            ["uuid": $0.uuid, "ManagedSpaceID": Int($0.managedSpaceID)]
        }
        spaces.append(["uuid": "TILE", "ManagedSpaceID": 9999, "TileLayoutManager": ["ignored": true]])
        return [
            "app-bindings": [String: String](),
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [
                        [
                            "Display Identifier": "Main",
                            "Current Space": ["uuid": currentSpaceUUID],
                            "Spaces": spaces,
                        ],
                    ],
                ],
            ],
        ]
    }

    func run(executable: String, arguments: [String]) throws -> Data {
        guard executable == "/usr/bin/defaults", arguments.first == "export" else { return Data() }
        return try PropertyListSerialization.data(
            fromPropertyList: storeDictionary(),
            format: .xml,
            options: 0
        )
    }
}

/// A window manipulator that reports every window as landing exactly where asked,
/// recording which bundle identifiers it was actually asked to move.
final class StubWindowManipulator: WindowManipulating {
    private(set) var moved: [String] = []
    func moveFrontmostStandardWindow(
        bundleIdentifier: String,
        toTopLeftFrame topLeftFrame: CGRect
    ) -> CGRect? {
        moved.append(bundleIdentifier)
        return topLeftFrame
    }
}

struct StubAuthorizer: AccessibilityAuthorizing {
    func ensureTrusted(promptIfNeeded: Bool) -> Bool { true }
}

struct StubScreenGeometry: ScreenGeometryProviding {
    var activeVisibleFrame: CGRect? = CGRect(x: 0, y: 0, width: 1000, height: 800)
    var primaryDisplayHeight: CGFloat = 800
}

let fullScreenLayout = Layout(
    horizontalDivision: .halves,
    verticalDivision: .halves,
    columnSpan: LayoutSpan(start: 0, end: 1),
    rowSpan: LayoutSpan(start: 0, end: 1)
)

func app(_ bundleID: String, desktop: Int, layout: Layout?) -> ManagedApplication {
    ManagedApplication(
        bundleIdentifier: bundleID,
        displayName: bundleID,
        desktopNumber: desktop,
        layout: layout
    )
}

@main
struct ActiveDesktopTestRunner {
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

        // The stale-store mismatch: ordered Desktops 1, 2, 3 carry managed Space
        // IDs 1, 2, 3; the store's Current Space still points at Desktop 3's UUID
        // (managed ID 3) even though the live session is on Desktop 1 (managed
        // ID 1).
        let desktops: [(uuid: String, managedSpaceID: UInt64)] = [
            (uuid: "D1", managedSpaceID: 1),
            (uuid: "D2", managedSpaceID: 2),
            (uuid: "D3", managedSpaceID: 3),
        ]

        // MARK: - Pure mapping: live managed Space ID → 1-based Desktop number.

        do {
            let store: [String: Any] = [
                "SpacesDisplayConfiguration": [
                    "Management Data": [
                        "Monitors": [
                            [
                                "Display Identifier": "Main",
                                "Current Space": ["uuid": "D3"],
                                "Spaces": desktops.map {
                                    ["uuid": $0.uuid, "ManagedSpaceID": Int($0.managedSpaceID)]
                                }
                                    + [["uuid": "TILE", "ManagedSpaceID": 9999, "TileLayoutManager": ["x": 1]]],
                            ],
                        ],
                    ],
                ],
            ]
            check(
                "the live active managed Space ID maps to its 1-based Desktop number",
                DisplayResolution.desktopNumber(forManagedSpaceID: 1, fromStore: store, displayKey: "Main") == 1,
                "got \(String(describing: DisplayResolution.desktopNumber(forManagedSpaceID: 1, fromStore: store, displayKey: "Main")))"
            )
            check(
                "the last ordered Desktop's managed Space ID maps to Desktop 3",
                DisplayResolution.desktopNumber(forManagedSpaceID: 3, fromStore: store, displayKey: "Main") == 3
            )
            check(
                "a managed Space ID absent from the ordered Desktops maps to nil (fail closed)",
                DisplayResolution.desktopNumber(forManagedSpaceID: 999, fromStore: store, displayKey: "Main") == nil
            )
        }

        // MARK: - Adapter: resolves the live Desktop, ignoring the stale store.

        do {
            let adapter = MacOSSpacesAdapter(
                commandRunner: StoreCommandRunner(desktops: desktops, currentSpaceUUID: "D3"),
                sessionBindingUpdater: StubSessionUpdater(),
                displayInventory: StubDisplayInventory(displays: [
                    ActiveDisplay(displayID: 1, isMain: true, mirrorsDisplayID: 0),
                ]),
                activeSpaceProvider: StubActiveSpaceProvider(managedSpaceID: 1)
            )
            let resolved = try? adapter.activeDesktopNumber()
            check(
                "Arrange resolves the live active Desktop (1), not the stale stored Current Space (Desktop 3)",
                resolved == 1,
                "got \(String(describing: resolved))"
            )
        }

        // MARK: - Adapter fails closed when the live active Space cannot be read.

        do {
            let adapter = MacOSSpacesAdapter(
                commandRunner: StoreCommandRunner(desktops: desktops, currentSpaceUUID: "D3"),
                sessionBindingUpdater: StubSessionUpdater(),
                displayInventory: StubDisplayInventory(displays: [
                    ActiveDisplay(displayID: 1, isMain: true, mirrorsDisplayID: 0),
                ]),
                activeSpaceProvider: StubActiveSpaceProvider(managedSpaceID: nil)
            )
            let resolved = try? adapter.activeDesktopNumber()
            check(
                "an unreadable live active Space resolves to nil rather than a guessed Desktop",
                (resolved ?? nil) == nil,
                "got \(String(describing: resolved))"
            )
        }

        // MARK: - Scoping: only the active Desktop's applications are passed.

        do {
            let applications = [
                app("com.desktop1.app", desktop: 1, layout: fullScreenLayout),
                app("com.desktop3.app", desktop: 3, layout: fullScreenLayout),
            ]
            let scoped = ArrangeEngine.applications(applications, assignedToDesktop: 1)
            check(
                "only Desktop 1's application is scoped into the active pass",
                scoped.map(\.bundleIdentifier) == ["com.desktop1.app"],
                "got \(scoped.map(\.bundleIdentifier))"
            )

            // Feeding the scoped set to the arranger proves the other Desktop's
            // application is never moved nor reported.
            let manipulator = StubWindowManipulator()
            let arranger = WindowArranger(
                authorizer: StubAuthorizer(),
                windowManipulator: manipulator,
                screenGeometry: StubScreenGeometry()
            )
            let report = try! arranger.arrange(managedApplications: scoped)
            check(
                "the arranger reports only Desktop 1's application",
                report.arranged == ["com.desktop1.app"],
                "got \(report.arranged)"
            )
            check(
                "Desktop 3's application is never moved during the active Desktop's pass",
                manipulator.moved.contains("com.desktop3.app") == false,
                "moved: \(manipulator.moved)"
            )
        }

        if failures.isEmpty {
            print("Active-Desktop Arrange tests passed")
        } else {
            fatalError("Active-Desktop Arrange tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
