import DeskLayouterMacOS
import Foundation

@main
struct DesktopPlacementTestRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: DeskLayouterDesktopPlacementTests BUNDLE_ID DESKTOP_UUID\n", stderr)
            exit(2)
        }

        try MacOSSpacesAdapter().apply(appBindings: [
            CommandLine.arguments[1]: CommandLine.arguments[2],
        ])
    }
}
