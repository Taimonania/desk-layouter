import DeskLayouterCore

@main
struct AssignmentPlannerTestRunner {
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

        let planner = AssignmentPlanner()

        // Single-assignment method (walking-skeleton seam, #3): resolves a
        // Desktop number to the correct UUID.
        do {
            let assignment = Assignment(
                bundleIdentifier: "com.example.Writer",
                desktopNumber: 2
            )
            let desktops = DesktopSnapshot(
                orderedDesktopUUIDs: ["desktop-one", "desktop-two", "desktop-three"]
            )
            let appBindings = try? planner.appBindings(for: assignment, on: desktops)
            check(
                "single assignment resolves number to UUID",
                appBindings == ["com.example.Writer": "desktop-two"],
                "got \(String(describing: appBindings))"
            )
        }

        // Single-assignment method still throws for a missing Desktop so the
        // single-assignment UI can report the specific bad Desktop number.
        do {
            let assignment = Assignment(
                bundleIdentifier: "com.example.Writer",
                desktopNumber: 5
            )
            let desktops = DesktopSnapshot(orderedDesktopUUIDs: ["only-one"])
            var threw = false
            do {
                _ = try planner.appBindings(for: assignment, on: desktops)
            } catch AssignmentPlanningError.desktopDoesNotExist(let number) {
                threw = (number == 5)
            } catch {
                threw = false
            }
            check("single assignment throws for a missing Desktop", threw)
        }

        // Collection planner: resolves a Desktop number to the correct UUID.
        do {
            let desktops = DesktopSnapshot(
                orderedDesktopUUIDs: ["desktop-one", "desktop-two", "desktop-three"]
            )
            let bindings = planner.appBindings(
                for: [Assignment(bundleIdentifier: "com.example.Writer", desktopNumber: 2)],
                on: desktops
            )
            check(
                "collection resolves number to UUID",
                bindings == ["com.example.Writer": "desktop-two"],
                "got \(bindings)"
            )
        }

        // Collection planner: an assignment to a Desktop that no longer exists
        // is skipped, and the remaining valid assignments still resolve.
        do {
            let desktops = DesktopSnapshot(
                orderedDesktopUUIDs: ["desktop-one", "desktop-two"]
            )
            let bindings = planner.appBindings(
                for: [
                    Assignment(bundleIdentifier: "com.example.Writer", desktopNumber: 1),
                    Assignment(bundleIdentifier: "com.example.Gone", desktopNumber: 9),
                    Assignment(bundleIdentifier: "com.example.Reader", desktopNumber: 2),
                ],
                on: desktops
            )
            check(
                "collection skips assignments to a missing Desktop",
                bindings == [
                    "com.example.Writer": "desktop-one",
                    "com.example.Reader": "desktop-two",
                ],
                "got \(bindings)"
            )
        }

        // Collection planner: a Desktop number below one is out of range and
        // skipped rather than resolving to a nonsense index.
        do {
            let desktops = DesktopSnapshot(orderedDesktopUUIDs: ["desktop-one"])
            let bindings = planner.appBindings(
                for: [Assignment(bundleIdentifier: "com.example.Zero", desktopNumber: 0)],
                on: desktops
            )
            check("collection skips a non-positive Desktop number", bindings.isEmpty, "got \(bindings)")
        }

        // Collection planner: apps the user has not added are never emitted —
        // only the given assignments appear in the output.
        do {
            let desktops = DesktopSnapshot(
                orderedDesktopUUIDs: ["desktop-one", "desktop-two"]
            )
            let bindings = planner.appBindings(
                for: [Assignment(bundleIdentifier: "com.example.Writer", desktopNumber: 1)],
                on: desktops
            )
            check(
                "collection emits only managed apps",
                bindings == ["com.example.Writer": "desktop-one"],
                "got \(bindings)"
            )
        }

        // Collection planner: an empty configuration produces an empty result.
        do {
            let desktops = DesktopSnapshot(
                orderedDesktopUUIDs: ["desktop-one", "desktop-two"]
            )
            let bindings = planner.appBindings(for: [], on: desktops)
            check("collection with empty configuration is empty", bindings.isEmpty, "got \(bindings)")
        }

        // Collection planner: no Desktops at all yields an empty result even
        // with assignments present.
        do {
            let bindings = planner.appBindings(
                for: [Assignment(bundleIdentifier: "com.example.Writer", desktopNumber: 1)],
                on: DesktopSnapshot(orderedDesktopUUIDs: [])
            )
            check("collection with no Desktops is empty", bindings.isEmpty, "got \(bindings)")
        }

        // Collection planner: multiple apps across multiple Desktops resolve
        // correctly.
        do {
            let desktops = DesktopSnapshot(
                orderedDesktopUUIDs: ["desktop-one", "desktop-two", "desktop-three"]
            )
            let bindings = planner.appBindings(
                for: [
                    Assignment(bundleIdentifier: "com.example.Writer", desktopNumber: 1),
                    Assignment(bundleIdentifier: "com.example.Reader", desktopNumber: 3),
                    Assignment(bundleIdentifier: "com.example.Mail", desktopNumber: 2),
                ],
                on: desktops
            )
            check(
                "collection resolves multiple apps across Desktops",
                bindings == [
                    "com.example.Writer": "desktop-one",
                    "com.example.Reader": "desktop-three",
                    "com.example.Mail": "desktop-two",
                ],
                "got \(bindings)"
            )
        }

        // Collection planner: the planner does no macOS-specific lowercase
        // normalization — bundle identifiers are emitted verbatim so the
        // adapter remains responsible for normalization.
        do {
            let desktops = DesktopSnapshot(orderedDesktopUUIDs: ["desktop-one"])
            let bindings = planner.appBindings(
                for: [Assignment(bundleIdentifier: "com.Example.MixedCase", desktopNumber: 1)],
                on: desktops
            )
            check(
                "collection preserves bundle-ID case (normalization stays in adapter)",
                bindings == ["com.Example.MixedCase": "desktop-one"],
                "got \(bindings)"
            )
        }

        if failures.isEmpty {
            print("Assignment planner tests passed")
        } else {
            fatalError("Assignment planner tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
