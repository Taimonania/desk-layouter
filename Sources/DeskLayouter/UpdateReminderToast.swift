import SwiftUI

/// The quiet in-window update reminder (issue #127): a small card that names the
/// available version with an **Install** button and a **Later** button. It appears
/// when a background check finds an update, without activating the app or stealing
/// focus. Install opens Sparkle's normal update dialog (release notes, Install,
/// Skip This Version, Remind Me Later), brought into focus, and dismisses the toast;
/// Later dismisses it for the session.
///
/// This view owns presentation only; the decision logic (whether it shows, on which
/// surface, and the display string) lives in the tested `UpdateReminder` seam, and
/// `AppRootView` drives it through the injected closures.
struct UpdateReminderToast: View {
    /// The headline, already resolved by the seam (named version or generic
    /// fallback), so this view never renders an empty version string.
    let message: String

    /// Opens Sparkle's update dialog and dismisses the toast.
    let onInstall: () -> Void

    /// Dismisses the toast for the remainder of the session.
    let onLater: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Later") { onLater() }
                .accessibilityLabel("Dismiss the update reminder")

            Button("Install") { onInstall() }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Install the update")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Update available. \(message).")
    }
}
