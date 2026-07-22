import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

/// Thin driver for the human-gated transactional multi-Display harness. It is
/// intentionally excluded from `make test`: snapshot is read-only, while apply
/// and arrange touch the real macOS system only when the shell harness invokes
/// them after recording restoration state.
@main
struct MultiDisplaySystemTestRunner {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            usage()
        }
        switch CommandLine.arguments[1] {
        case "snapshot":
            try snapshot()
        case "apply":
            guard CommandLine.arguments.count == 3 else { usage() }
            let configuration = try configuration(at: CommandLine.arguments[2])
            let adapter = MacOSSpacesAdapter()
            let topology = try adapter.currentDisplayTopology()
            let plan = AssignmentPlanner().applyPlan(configuration: configuration, on: topology)
            try adapter.apply(plan: plan, expectedTopology: topology)
        case "plan":
            guard CommandLine.arguments.count == 3 else { usage() }
            let configuration = try configuration(at: CommandLine.arguments[2])
            let topology = try MacOSSpacesAdapter().currentDisplayTopology()
            let plan = AssignmentPlanner().applyPlan(configuration: configuration, on: topology)
            try printPlan(plan)
        case "arrange":
            guard CommandLine.arguments.count == 3 else { usage() }
            let configuration = try configuration(at: CommandLine.arguments[2])
            try arrange(configuration)
        default:
            usage()
        }
    }

    private static func snapshot() throws {
        let adapter = MacOSSpacesAdapter()
        let topology = try adapter.currentDisplayTopology()
        let active = try adapter.activeDesktopDestinations(in: topology)
        let sections: [[String: Any]] = topology.sections.map { section in
            let activeNumber = active.first {
                $0.display.identifiesSameDisplay(as: section.primaryDisplay)
            }?.desktopNumber
            return [
                "identity": identityObject(section.primaryDisplay),
                "memberIdentities": section.memberDisplays.map(identityObject),
                "displayName": topology.displayName(for: section),
                "isMain": section.isMain,
                "isBuiltIn": section.isBuiltIn,
                "isMirrored": section.isMirrored,
                "desktopUUIDs": section.orderedDesktopUUIDs,
                "activeDesktopNumber": activeNumber as Any,
                "bounds": [
                    "x": section.bounds.x,
                    "y": section.bounds.y,
                    "width": section.bounds.width,
                    "height": section.bounds.height,
                ],
            ]
        }
        let object: [String: Any] = [
            "displaysHaveSeparateSpaces": topology.displaysHaveSeparateSpaces,
            "automaticallyRearrangesSpaces": topology.automaticallyRearrangesSpaces,
            "sections": sections,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func arrange(_ configuration: DeskLayouterConfiguration) throws {
        let adapter = MacOSSpacesAdapter()
        let topology = try adapter.currentDisplayTopology()
        guard topology.displaysHaveSeparateSpaces else {
            throw SpacesAdapterError.separateSpacesRequired
        }
        let active = try adapter.activeDesktopDestinations(in: topology)
        let arranger = WindowArranger()
        var output: [[String: Any]] = []
        for destination in active.sorted(by: destinationOrder(topology)) {
            let applications = ArrangeEngine.applications(
                configuration.managedApplications,
                assignedTo: destination,
                in: topology
            )
            guard !applications.isEmpty else { continue }
            let report = try arranger.arrange(
                managedApplications: applications,
                on: destination.display
            )
            output.append([
                "displayUUID": destination.display.colorSyncUUID,
                "desktopNumber": destination.desktopNumber,
                "arranged": report.arranged,
                "skipped": report.skipped,
                "resisted": report.resisted.map(\.bundleIdentifier),
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func printPlan(_ plan: AssignmentApplyPlan) throws {
        let object: [String: Any] = [
            "updates": plan.updates,
            "deletions": plan.deletions.sorted(),
            "preservations": plan.preservations.sorted(),
            "invalidDesktopAssignments": plan.invalidDesktopAssignments.sorted(),
            "canMutate": plan.canMutate,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func destinationOrder(
        _ topology: DisplayTopologySnapshot
    ) -> (DesktopAddress, DesktopAddress) -> Bool {
        let order = Dictionary(uniqueKeysWithValues: topology.sections.enumerated().map {
            ($0.element.primaryDisplay.colorSyncUUID.lowercased(), $0.offset)
        })
        return { lhs, rhs in
            let l = order[lhs.display.colorSyncUUID.lowercased()] ?? .max
            let r = order[rhs.display.colorSyncUUID.lowercased()] ?? .max
            return l == r ? lhs.desktopNumber < rhs.desktopNumber : l < r
        }
    }

    private static func configuration(at path: String) throws -> DeskLayouterConfiguration {
        try ConfigurationSerialization.decode(from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func identityObject(_ identity: DisplayIdentity) -> [String: Any] {
        var object: [String: Any] = [
            "colorSyncUUID": identity.colorSyncUUID,
            "lastKnownName": identity.lastKnownName,
        ]
        if let value = identity.vendorID { object["vendorID"] = value }
        if let value = identity.modelID { object["modelID"] = value }
        if let value = identity.serialNumber { object["serialNumber"] = value }
        return object
    }

    private static func usage() -> Never {
        fputs("usage: DeskLayouterMultiDisplaySystemTests snapshot | plan CONFIG.json | apply CONFIG.json | arrange CONFIG.json\n", stderr)
        exit(2)
    }
}
