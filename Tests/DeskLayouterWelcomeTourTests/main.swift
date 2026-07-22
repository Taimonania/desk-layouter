import DeskLayouterMacOS

@main
struct WelcomeTourTestRunner {
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

        // MARK: - First-run gate

        do {
            let tour = WelcomeTour.onLaunch(hasSeenWelcome: false)
            check(
                "a fresh install presents Welcome from the first step",
                tour.isPresented && tour.currentStep == .addApps,
                "presented=\(tour.isPresented) step=\(tour.currentStep)"
            )
        }

        do {
            let tour = WelcomeTour.onLaunch(hasSeenWelcome: true)
            check(
                "a returning launch does not present Welcome",
                !tour.isPresented,
                "presented=\(tour.isPresented)"
            )
        }

        // MARK: - Step count / index / bounds

        do {
            let tour = WelcomeTour()
            check("there are exactly three steps", tour.stepCount == 3, "got \(tour.stepCount)")
            check("the tour starts on the first step", tour.currentStep == .addApps)
            check("a default tour is not presented", !tour.isPresented)
            check("stepIndex is zero on the first step", tour.stepIndex == 0, "got \(tour.stepIndex)")
            check("the first step is flagged first", tour.isFirstStep)
            check("the first step is not the last", !tour.isLastStep)
        }

        // MARK: - Next / Back

        do {
            var tour = WelcomeTour(isPresented: true)
            tour.next()
            check("next advances to Apply", tour.currentStep == .apply, "got \(tour.currentStep)")
            check("stepIndex is 1 on the second step", tour.stepIndex == 1)
            check("the middle step is neither first nor last", !tour.isFirstStep && !tour.isLastStep)
            tour.next()
            check("next advances to Go further", tour.currentStep == .goFurther, "got \(tour.currentStep)")
            check("the third step is flagged last", tour.isLastStep)
            check("stepIndex is 2 on the last step", tour.stepIndex == 2)
        }

        do {
            var tour = WelcomeTour(isPresented: true, currentStep: .goFurther)
            tour.next()
            check("next on the last step is a no-op", tour.currentStep == .goFurther)
            check("next on the last step keeps the tour presented", tour.isPresented)
        }

        do {
            var tour = WelcomeTour(isPresented: true, currentStep: .goFurther)
            tour.back()
            check("back retreats to Apply", tour.currentStep == .apply, "got \(tour.currentStep)")
            tour.back()
            check("back retreats to Add apps", tour.currentStep == .addApps)
            tour.back()
            check("back on the first step is a no-op", tour.currentStep == .addApps)
        }

        // MARK: - Skip / Done dismissal

        do {
            var tour = WelcomeTour(isPresented: true, currentStep: .addApps)
            tour.dismiss()
            check("Skip dismisses from any step", !tour.isPresented)
        }

        do {
            var tour = WelcomeTour(isPresented: true, currentStep: .goFurther)
            tour.dismiss()
            check("Done dismisses on the last step", !tour.isPresented)
        }

        // MARK: - Re-open (Help button)

        do {
            var tour = WelcomeTour(isPresented: false, currentStep: .goFurther)
            tour.open()
            check("open presents the tour", tour.isPresented)
            check("open resets to the first step", tour.currentStep == .addApps, "got \(tour.currentStep)")
        }

        // MARK: - Per-step content + spotlight targets

        do {
            check(
                "Add apps spotlights the search field and destination picker",
                WelcomeTour.Step.addApps.spotlightTargets == [.searchField, .destinationPicker]
            )
            check(
                "Apply spotlights the Apply button",
                WelcomeTour.Step.apply.spotlightTargets == [.applyButton]
            )
            check(
                "Go further spotlights the live Arrange button",
                WelcomeTour.Step.goFurther.spotlightTargets == [.arrangeButton]
            )
            check(
                "only the final step shows the recreated sample card",
                !WelcomeTour.Step.addApps.showsSampleCard
                    && !WelcomeTour.Step.apply.showsSampleCard
                    && WelcomeTour.Step.goFurther.showsSampleCard
            )
            check(
                "every step has non-empty title and message copy",
                WelcomeTour.Step.allCases.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty }
            )
        }

        if failures.isEmpty {
            print("Welcome tour tests passed")
        } else {
            fatalError("Welcome tour tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
