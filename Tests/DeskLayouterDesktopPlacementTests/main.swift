import DeskLayouterMacOS
import Foundation

/// Thin real-system driver: parses the desired managed bindings and the managed
/// ownership set, then applies them through the production adapter. The
/// transactional shell harness (`Scripts/verify-desktop-placement.sh`) drives
/// this across multiple applies to exercise add, change, and removal.
@main
struct DesktopPlacementTestRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs(
                "usage: DeskLayouterDesktopPlacementTests MANAGED_BINDINGS_JSON MANAGED_BUNDLE_IDS_JSON\n",
                stderr
            )
            exit(2)
        }

        let managedBindings = try decodeStringDictionary(CommandLine.arguments[1])
        let managedBundleIdentifiers = try decodeStringArray(CommandLine.arguments[2])

        try MacOSSpacesAdapter().apply(
            managedBindings: managedBindings,
            managedBundleIdentifiers: Set(managedBundleIdentifiers)
        )
    }

    private static func decodeStringDictionary(_ json: String) throws -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private static func decodeStringArray(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }
}
