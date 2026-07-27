import DeskLayouterMacOS

@main
struct UpdateReminderTestRunner {
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

        // MARK: - A background check that finds an update shows a toast

        do {
            var reminder = UpdateReminder()
            check("nothing is pending before any check", reminder.pending == nil)
            check("no toast on the board before any check", !reminder.isToastVisible(on: .board))

            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            check("a background check records a pending update", reminder.pending != nil)
            check("the toast is visible on the board", reminder.isToastVisible(on: .board))
            check(
                "the toast names the found version",
                reminder.toastMessage == "Version 0.4.2 is available",
                "\(reminder.toastMessage ?? "nil")"
            )
        }

        // MARK: - An update Sparkle is handling (a user-initiated check) shows none

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: true, versionName: "0.4.2")
            check("a Sparkle-handled update records nothing", reminder.pending == nil)
            check("no toast for a Sparkle-handled update", !reminder.isToastVisible(on: .board))
            check("no toast message for a Sparkle-handled update", reminder.toastMessage == nil)
        }

        // MARK: - Per-surface toast visibility

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            check("the toast is visible on the board", reminder.isToastVisible(on: .board))
            check("the toast is visible on Settings", reminder.isToastVisible(on: .settings))
            check("the toast is hidden on What's-New", !reminder.isToastVisible(on: .whatsNew))
        }

        // MARK: - Dismissal clears the toast

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            reminder.dismiss()
            check("dismiss clears the pending update", reminder.pending == nil)
            check("dismiss hides the toast", !reminder.isToastVisible(on: .board))
            check("dismiss clears the toast message", reminder.toastMessage == nil)
        }

        // MARK: - A later found update after a dismissal is shown again

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            reminder.dismiss()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.3")
            check("a later found update makes the toast reappear", reminder.isToastVisible(on: .board))
            check(
                "the toast names the newer version",
                reminder.toastMessage == "Version 0.4.3 is available",
                "\(reminder.toastMessage ?? "nil")"
            )
        }

        // MARK: - Menu-bar badge visibility is a property of the pending state (#128)

        do {
            var reminder = UpdateReminder()
            check("no badge before any check", !reminder.isBadgeVisible)

            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            check("a background check shows the badge", reminder.isBadgeVisible)
        }

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: true, versionName: "0.4.2")
            check("no badge for a Sparkle-handled (user-initiated) update", !reminder.isBadgeVisible)
        }

        do {
            // The badge is independent of the surface the window is showing: the toast
            // hides on What's-New while the badge stays lit, and the badge is lit on
            // every surface for the same pending update.
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            check("the badge is lit while on the board", reminder.isBadgeVisible)
            check("the badge stays lit on Settings", reminder.isBadgeVisible)
            check(
                "the badge stays lit on What's-New even though the toast is hidden there",
                reminder.isBadgeVisible && !reminder.isToastVisible(on: .whatsNew)
            )
        }

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            reminder.dismiss()
            check("dismiss clears the badge", !reminder.isBadgeVisible)
        }

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.2")
            reminder.dismiss()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "0.4.3")
            check("a later found update re-lights the badge", reminder.isBadgeVisible)
        }

        // MARK: - Version-name fallback (never renders an empty string)

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: nil)
            check("a missing version name still shows a toast", reminder.isToastVisible(on: .board))
            check(
                "a missing version name falls back to generic wording",
                reminder.toastMessage == "A new version is available",
                "\(reminder.toastMessage ?? "nil")"
            )
        }

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "")
            check(
                "an empty version name falls back to generic wording",
                reminder.toastMessage == "A new version is available",
                "\(reminder.toastMessage ?? "nil")"
            )
        }

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "   ")
            check(
                "a whitespace-only version name falls back to generic wording",
                reminder.toastMessage == "A new version is available",
                "\(reminder.toastMessage ?? "nil")"
            )
        }

        do {
            var reminder = UpdateReminder()
            reminder.recordFoundUpdate(handledBySparkle: false, versionName: "  0.4.2  ")
            check(
                "a padded version name is trimmed rather than shown with surrounding spaces",
                reminder.toastMessage == "Version 0.4.2 is available",
                "\(reminder.toastMessage ?? "nil")"
            )
        }

        if failures.isEmpty {
            print("Update-reminder tests passed")
        } else {
            fatalError("Update-reminder tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
