import DeskLayouterCore

@main
struct AssignmentPlannerTestRunner {
    static func main() throws {
        let assignment = Assignment(
            bundleIdentifier: "com.example.Writer",
            desktopNumber: 2
        )
        let desktops = DesktopSnapshot(
            orderedDesktopUUIDs: ["desktop-one", "desktop-two", "desktop-three"]
        )

        let appBindings = try AssignmentPlanner().appBindings(
            for: assignment,
            on: desktops
        )

        let expected = ["com.example.Writer": "desktop-two"]
        guard appBindings == expected else {
            fatalError("Expected \(expected), received \(appBindings)")
        }

        print("Assignment planner tests passed")
    }
}
