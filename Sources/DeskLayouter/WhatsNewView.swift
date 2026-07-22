import DeskLayouterCore
import DeskLayouterMacOS
import SwiftUI

/// The full-window What's-New surface (issue #73), shown on the first launch after
/// the app version increases. It replaces the board in the same window (reusing the
/// in-window surface-swap navigation, like Settings) rather than opening a sheet or
/// a second window. It shows a "You now run vX.Y.Z" headline plus the highlights of
/// every version reached since the last one seen — grouped under a per-version
/// heading when several were skipped — and a "Done" control that returns to the
/// board. All presentation state comes from the pure `WhatsNew` seam.
struct WhatsNewView: View {
    @ObservedObject var model: AppRootModel

    /// The content to render. Absent only in the brief window between dismissal and
    /// the surface swap; an empty placeholder keeps the view total.
    private var whatsNew: WhatsNew? { model.whatsNew }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's New")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let whatsNew {
                        Text("You now run \(AppVersion.displayString(fromShortVersion: whatsNew.version))")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Done") {
                    model.dismissWhatsNew()
                }
                .keyboardShortcut(.defaultAction)
                .help("Return to the board")
                .accessibilityLabel("Done, return to the board")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let whatsNew {
                        let showVersionHeadings = whatsNew.sections.count > 1
                        ForEach(whatsNew.sections, id: \.version) { entry in
                            section(entry, showVersionHeading: showVersionHeadings)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: AppWindowMetrics.minWidth, minHeight: AppWindowMetrics.minHeight)
    }

    /// One version's highlights. The per-version heading (version + date) is shown
    /// only when several versions were skipped, so a single-version upgrade — whose
    /// version the headline already states — is not redundantly labeled.
    @ViewBuilder
    private func section(_ entry: ChangelogEntry, showVersionHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showVersionHeading {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppVersion.displayString(fromShortVersion: entry.version))
                        .font(.headline)
                    if !entry.date.isEmpty {
                        Text(entry.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Version \(entry.version)\(entry.date.isEmpty ? "" : ", \(entry.date)")"
                )
            }
            ForEach(Array(entry.highlights.enumerated()), id: \.offset) { _, highlight in
                Label {
                    Text(highlight)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.tint)
                }
                .accessibilityLabel(highlight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
