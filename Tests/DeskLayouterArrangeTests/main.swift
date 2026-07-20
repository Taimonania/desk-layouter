import CoreGraphics
import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

// Verifies the runtime Arrange engine (issue #25, ADR-0003): which managed apps
// qualify (non-nil valid Layout), the bottom-left → top-left coordinate flip
// taken against the PRIMARY display height on single- and multi-display
// geometry, resisted-window detection, and the orchestration loop (permission
// gating, skipping apps with no eligible window, collecting resisted windows).
// The live AXUIElement / NSScreen side effects are injected seams, so none of
// this touches real hardware or the Accessibility trust database. Hand-rolled
// @main runner, no XCTest — matching the other test targets.

/// An authorizer whose trust answer and prompt behaviour are controlled by the
/// test.
final class StubAuthorizer: AccessibilityAuthorizing {
    var trusted: Bool
    private(set) var promptRequests: [Bool] = []

    init(trusted: Bool) { self.trusted = trusted }

    func ensureTrusted(promptIfNeeded: Bool) -> Bool {
        promptRequests.append(promptIfNeeded)
        return trusted
    }
}

/// A window manipulator backed by a scripted table: for each bundle id, either
/// no eligible window (absent key), or the frame to report as read back given a
/// requested frame. Records every move so the test can assert the size →
/// position → size call actually happened.
final class StubWindowManipulator: WindowManipulating {
    /// bundle id → transform from the requested frame to the frame read back.
    /// A missing entry models "no eligible window" (skip).
    var readback: [String: (CGRect) -> CGRect]
    private(set) var moves: [(bundleIdentifier: String, frame: CGRect)] = []

    init(readback: [String: (CGRect) -> CGRect]) { self.readback = readback }

    func moveFrontmostStandardWindow(
        bundleIdentifier: String,
        toTopLeftFrame topLeftFrame: CGRect
    ) -> CGRect? {
        moves.append((bundleIdentifier, topLeftFrame))
        guard let transform = readback[bundleIdentifier] else { return nil }
        return transform(topLeftFrame)
    }
}

/// Fully controlled screen geometry.
struct StubScreenGeometry: ScreenGeometryProviding {
    var activeVisibleFrame: CGRect?
    var primaryDisplayHeight: CGFloat
}

func app(_ bundleID: String, layout: Layout?) -> ManagedApplication {
    ManagedApplication(
        bundleIdentifier: bundleID,
        displayName: bundleID,
        desktopNumber: 1,
        layout: layout
    )
}

let fullScreenLayout = Layout(
    horizontalDivision: .halves,
    verticalDivision: .halves,
    columnSpan: LayoutSpan(start: 0, end: 1),
    rowSpan: LayoutSpan(start: 0, end: 1)
)

@main
struct ArrangeTestRunner {
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

        func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
        func rectsEqual(_ a: CGRect, _ b: CGRect) -> Bool {
            approx(a.minX, b.minX) && approx(a.minY, b.minY)
                && approx(a.width, b.width) && approx(a.height, b.height)
        }

        // MARK: - Candidate selection.

        do {
            let valid = fullScreenLayout
            let invalid = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: LayoutSpan(start: 0, end: 5), // out of bounds
                rowSpan: .single(0)
            )
            let candidates = ArrangeEngine.candidates(from: [
                app("com.with.layout", layout: valid),
                app("com.no.layout", layout: nil),
                app("com.invalid.layout", layout: invalid),
            ])
            check(
                "only apps with a non-nil valid Layout are candidates",
                candidates.map(\.bundleIdentifier) == ["com.with.layout"],
                "got \(candidates.map(\.bundleIdentifier))"
            )
        }

        // MARK: - Coordinate flip, single display.

        do {
            // A 1440-tall primary display. A rect sitting at the bottom-left in
            // NSScreen space (y = 0) must flip to the top-left plane so its top
            // edge is (primaryHeight - height) from the top.
            let screenRect = CGRect(x: 100, y: 0, width: 800, height: 600)
            let flipped = ArrangeEngine.topLeftFrame(
                fromScreenFrame: screenRect,
                primaryDisplayHeight: 1440
            )
            check(
                "single-display flip: x unchanged, y = primaryHeight - screenY - height",
                rectsEqual(flipped, CGRect(x: 100, y: 1440 - 0 - 600, width: 800, height: 600)),
                "got \(flipped)"
            )
        }

        do {
            // A rect flush against the top of the screen (screenY + height =
            // primaryHeight) flips to y = 0 in the top-left plane.
            let screenRect = CGRect(x: 0, y: 1440 - 600, width: 800, height: 600)
            let flipped = ArrangeEngine.topLeftFrame(
                fromScreenFrame: screenRect,
                primaryDisplayHeight: 1440
            )
            check(
                "single-display flip: a top-flush rect lands at y = 0",
                rectsEqual(flipped, CGRect(x: 0, y: 0, width: 800, height: 600)),
                "got \(flipped)"
            )
        }

        // MARK: - Coordinate flip, multi-display.

        do {
            // A secondary display extends ABOVE the primary: its NSScreen frame
            // has a positive y beyond the primary height. The flip must still be
            // taken against the PRIMARY height, producing a negative top-left y
            // (the window sits above the primary's top edge). Flipping against
            // the secondary's own height would be wrong.
            let primaryHeight: CGFloat = 1080
            // Window on a taller secondary above the primary: y from 1080 to 2520.
            let screenRect = CGRect(x: 0, y: 1080, width: 800, height: 600)
            let flipped = ArrangeEngine.topLeftFrame(
                fromScreenFrame: screenRect,
                primaryDisplayHeight: primaryHeight
            )
            check(
                "multi-display flip is taken against the primary height, not the window's screen",
                rectsEqual(flipped, CGRect(x: 0, y: 1080 - 1080 - 600, width: 800, height: 600)),
                "got \(flipped)"
            )
            check("multi-display window above the primary flips to a negative y", flipped.origin.y == -600)
        }

        // MARK: - framesMatch tolerance.

        do {
            let target = CGRect(x: 10, y: 20, width: 300, height: 400)
            check(
                "a sub-point difference counts as a match",
                ArrangeEngine.framesMatch(target, CGRect(x: 10.5, y: 20, width: 300, height: 399.6))
            )
            check(
                "a large clamp does not match",
                ArrangeEngine.framesMatch(target, CGRect(x: 10, y: 20, width: 300, height: 250)) == false
            )
            check(
                "a null read-back never matches",
                ArrangeEngine.framesMatch(target, .null) == false
            )
        }

        // MARK: - Orchestration: permission gate.

        do {
            let authorizer = StubAuthorizer(trusted: false)
            let manipulator = StubWindowManipulator(readback: ["com.a": { $0 }])
            let arranger = WindowArranger(
                authorizer: authorizer,
                windowManipulator: manipulator,
                screenGeometry: StubScreenGeometry(
                    activeVisibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    primaryDisplayHeight: 800
                )
            )
            var thrown: Error?
            do {
                _ = try arranger.arrange(managedApplications: [app("com.a", layout: fullScreenLayout)])
            } catch {
                thrown = error
            }
            check(
                "arrange throws accessibilityNotGranted when untrusted",
                (thrown as? WindowArrangeError) == .accessibilityNotGranted,
                "got \(String(describing: thrown))"
            )
            check("the user was prompted for permission", authorizer.promptRequests == [true])
            check("nothing is moved when permission is missing", manipulator.moves.isEmpty)
        }

        // MARK: - Orchestration: no active screen.

        do {
            let arranger = WindowArranger(
                authorizer: StubAuthorizer(trusted: true),
                windowManipulator: StubWindowManipulator(readback: [:]),
                screenGeometry: StubScreenGeometry(activeVisibleFrame: nil, primaryDisplayHeight: 800)
            )
            var thrown: Error?
            do {
                _ = try arranger.arrange(managedApplications: [app("com.a", layout: fullScreenLayout)])
            } catch {
                thrown = error
            }
            check(
                "arrange throws noActiveScreen when no screen resolves",
                (thrown as? WindowArrangeError) == .noActiveScreen,
                "got \(String(describing: thrown))"
            )
        }

        // MARK: - Orchestration: zero primary height fails closed.

        do {
            let arranger = WindowArranger(
                authorizer: StubAuthorizer(trusted: true),
                windowManipulator: StubWindowManipulator(readback: [:]),
                screenGeometry: StubScreenGeometry(
                    activeVisibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    primaryDisplayHeight: 0
                )
            )
            var thrown: Error?
            do {
                _ = try arranger.arrange(managedApplications: [app("com.a", layout: fullScreenLayout)])
            } catch {
                thrown = error
            }
            check(
                "arrange fails closed (noActiveScreen) rather than flipping against a zero height",
                (thrown as? WindowArrangeError) == .noActiveScreen,
                "got \(String(describing: thrown))"
            )
        }

        // MARK: - Orchestration: arrange / skip / resist in one pass.

        do {
            // Usable area 1000x800 with the origin at the bottom-left of an
            // 800-tall primary — so the flip is easy to read.
            let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let leftHalf = Layout(
                horizontalDivision: .halves,
                verticalDivision: .halves,
                columnSpan: .single(0),
                rowSpan: LayoutSpan(start: 0, end: 1)
            )
            // Expected screen-plane rect for the left half: x 0..500, full height.
            // Flip against 800: y = 800 - 0 - 800 = 0.
            let expectedTopLeft = CGRect(x: 0, y: 0, width: 500, height: 800)

            let manipulator = StubWindowManipulator(readback: [
                // Obedient window: reports back exactly what was asked.
                "com.obedient": { $0 },
                // Resistant window: clamps to a fixed 400x300 at the origin.
                "com.resistant": { _ in CGRect(x: 0, y: 0, width: 400, height: 300) },
                // "com.absent" intentionally missing → no eligible window.
            ])
            let arranger = WindowArranger(
                authorizer: StubAuthorizer(trusted: true),
                windowManipulator: manipulator,
                screenGeometry: StubScreenGeometry(
                    activeVisibleFrame: visible,
                    primaryDisplayHeight: 800
                )
            )

            let report = try! arranger.arrange(managedApplications: [
                app("com.obedient", layout: leftHalf),
                app("com.resistant", layout: leftHalf),
                app("com.absent", layout: leftHalf),
                app("com.nolayout", layout: nil),
            ])

            check(
                "the obedient window is reported arranged",
                report.arranged == ["com.obedient"],
                "got \(report.arranged)"
            )
            check(
                "the app with no eligible window is skipped without error",
                report.skipped == ["com.absent"],
                "got \(report.skipped)"
            )
            check(
                "the resistant window is collected, not silently dropped",
                report.resisted.map(\.bundleIdentifier) == ["com.resistant"],
                "got \(report.resisted.map(\.bundleIdentifier))"
            )
            check("hasResistance reflects the collected resisted window", report.hasResistance)
            check(
                "the resisted report carries desired and actual frames",
                report.resisted.first.map { rectsEqual($0.desiredFrame, expectedTopLeft) } == true
                    && report.resisted.first.map {
                        rectsEqual($0.actualFrame, CGRect(x: 0, y: 0, width: 400, height: 300))
                    } == true,
                "got \(String(describing: report.resisted.first))"
            )
            check(
                "the obedient window was asked for the flipped top-left frame",
                manipulator.moves.first { $0.bundleIdentifier == "com.obedient" }
                    .map { rectsEqual($0.frame, expectedTopLeft) } == true,
                "got \(String(describing: manipulator.moves.first { $0.bundleIdentifier == "com.obedient" }))"
            )
            check(
                "an app without a Layout is never touched",
                manipulator.moves.contains { $0.bundleIdentifier == "com.nolayout" } == false
            )
        }

        if failures.isEmpty {
            print("Arrange tests passed")
        } else {
            fatalError("Arrange tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
