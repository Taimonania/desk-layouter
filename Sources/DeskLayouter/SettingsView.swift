import AppKit
import DeskLayouterCore
import DeskLayouterMacOS
import SwiftUI

/// The full-window Settings surface (issue #71). It replaces the board in the same
/// window rather than opening a sheet or a separate window, reusing the in-window
/// surface-swap navigation. It hosts update preferences and the app's GitHub-only
/// support path, plus a "Done" control that returns to the board.
struct SettingsView: View {
    @ObservedObject var model: AppRootModel

    /// Layout constants for the hand-rolled settings column (issue #98).
    private enum Metrics {
        /// Caps the content as a stable left-aligned column so widening the
        /// window never reflows or stretches rows and captions.
        static let columnWidth: CGFloat = 560
        /// Generous gap that reads the Updates and Support blocks as separate.
        static let sectionSpacing: CGFloat = 30
        /// Tight grouping between a section's header, control, and caption.
        static let groupSpacing: CGFloat = 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                updatesSection
                supportSection
            }
            .frame(maxWidth: Metrics.columnWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: AppWindowConfiguration.minWidth, minHeight: AppWindowConfiguration.minHeight)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            Button("Done") {
                model.showBoard()
            }
            .keyboardShortcut(.defaultAction)
            .help("Return to the board")
            .accessibilityLabel("Done, return to the board")
        }
    }

    private var updatesSection: some View {
        section(
            "Updates",
            caption: "Desk Layouter always checks for updates automatically. This setting only controls whether an available update installs on its own. When it's off, you'll be asked before installing. Changes take effect the next time you launch Desk Layouter."
        ) {
            Toggle(
                "Automatically install updates",
                isOn: Binding(
                    get: { model.automaticallyInstallUpdates },
                    set: { model.automaticallyInstallUpdates = $0 }
                )
            )
            .toggleStyle(.switch)
            .fixedSize()
        }
    }

    private var supportSection: some View {
        section(
            "Support",
            caption: "Opens a prefilled GitHub issue requesting your Desk Layouter version, macOS version, expected behavior, and actual behavior."
        ) {
            Button("Report a Problem") {
                NSWorkspace.shared.open(
                    SupportReport.githubIssueURL(
                        appVersion: AppVersion.current(),
                        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
                    )
                )
            }
            .accessibilityHint("Opens a prefilled GitHub issue in your browser")
        }
    }

    /// One flat section: a bold header, its control, then an explanatory caption,
    /// grouped tightly. Sections are spaced apart by the enclosing stack.
    @ViewBuilder
    private func section(
        _ title: String,
        caption: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.groupSpacing) {
            Text(title)
                .font(.headline)

            control()

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
