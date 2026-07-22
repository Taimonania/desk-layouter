/// The on-screen element a Welcome tour step spotlights. These are stable
/// identifiers for the real controls the overlay dims around; the executable maps
/// each to a live view via an anchor preference. Kept in the library (not the
/// executable) so the step → target mapping stays part of the tested seam.
public enum WelcomeSpotlightTarget: Hashable, Sendable {
    /// The search-to-add field in the board header row.
    case searchField
    /// The "Add to" destination-Desktop picker beside the search field.
    case destinationPicker
    /// The Apply button that writes Assignments into macOS.
    case applyButton
    /// The Arrange button that positions live windows per their Layouts.
    case arrangeButton
}

/// The Welcome guided tour's step and presentation state (issue #72). A live
/// spotlight overlay dims the board and highlights the real element each step
/// describes; this value type owns only the *logic* — which step is shown, how
/// Next/Back/Skip/Done move through the tour, and whether it is presented — so the
/// navigation is tested at its seam without a running app or SwiftUI. The
/// executable wraps it in an `ObservableObject` to drive the overlay and to
/// persist the `hasSeenWelcome` flag on dismissal.
///
/// (Named a "tour" rather than a "screen"/"surface" because it floats *over* the
/// board rather than replacing it the way the Settings surface does.)
public struct WelcomeTour: Equatable, Sendable {
    /// The tour's three steps, in order. The raw value is the zero-based step
    /// index, which also drives the progress dots.
    public enum Step: Int, CaseIterable, Sendable {
        /// Spotlight the search field + the "Add to" Desktop picker.
        case addApps
        /// Spotlight the Apply button (macOS then enforces Assignments).
        case apply
        /// A recreated app card with its Layout icon highlighted, plus a spotlight
        /// on the live Arrange button.
        case goFurther

        /// The callout card's heading for this step.
        public var title: String {
            switch self {
            case .addApps: return "Add apps"
            case .apply: return "Apply your setup"
            case .goFurther: return "Go further with Layouts"
            }
        }

        /// The callout card's body copy for this step.
        public var message: String {
            switch self {
            case .addApps:
                return "Search for an application, then choose the Desktop to add it to. Editing the board changes only Desk Layouter — nothing moves yet."
            case .apply:
                return "Apply writes your Assignments into macOS. From then on each app opens on the Desktop you picked, at launch and at login."
            case .goFurther:
                return "Give an app a Layout to say where its window sits on its Desktop, then use Arrange to position the live windows."
            }
        }

        /// The live controls this step dims around. Step 3 spotlights the live
        /// Arrange button; its recreated app card is drawn inside the callout
        /// itself (the board is empty on first run) rather than anchored here.
        public var spotlightTargets: [WelcomeSpotlightTarget] {
            switch self {
            case .addApps: return [.searchField, .destinationPicker]
            case .apply: return [.applyButton]
            case .goFurther: return [.arrangeButton]
            }
        }

        /// Whether this step shows the recreated app card in its callout (true only
        /// for the final "Go further" step, since the board has no live card on
        /// first run to anchor to).
        public var showsSampleCard: Bool {
            self == .goFurther
        }
    }

    /// Whether the tour is currently shown over the board.
    public private(set) var isPresented: Bool

    /// The step currently shown.
    public private(set) var currentStep: Step

    public init(isPresented: Bool = false, currentStep: Step = .addApps) {
        self.isPresented = isPresented
        self.currentStep = currentStep
    }

    /// The tour to start with at launch. On a fresh install (`hasSeenWelcome ==
    /// false`) the Welcome tour is presented from its first step; once seen it
    /// stays dismissed. This is the first-run gate — a fresh install always shows
    /// Welcome and never the What's-New screen (issue #72).
    public static func onLaunch(hasSeenWelcome: Bool) -> WelcomeTour {
        WelcomeTour(isPresented: !hasSeenWelcome, currentStep: .addApps)
    }

    /// The current step's zero-based index, for the progress dots.
    public var stepIndex: Int { currentStep.rawValue }

    /// The total number of steps, for the progress dots.
    public var stepCount: Int { Step.allCases.count }

    /// Whether the current step is the first — Back is unavailable here.
    public var isFirstStep: Bool { currentStep == Step.allCases.first }

    /// Whether the current step is the last — the primary control reads "Done"
    /// here instead of "Next".
    public var isLastStep: Bool { currentStep == Step.allCases.last }

    /// Presents the tour from its first step. Used by the Help (`?`) button to
    /// re-open the tour on demand at any time.
    public mutating func open() {
        isPresented = true
        currentStep = .addApps
    }

    /// Advances to the next step. A no-op on the last step (the last step's primary
    /// control is Done, not Next).
    public mutating func next() {
        guard let step = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = step
    }

    /// Returns to the previous step. A no-op on the first step.
    public mutating func back() {
        guard let step = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = step
    }

    /// Dismisses the tour. Both Skip (any step) and Done (last step) route here;
    /// the executable persists `hasSeenWelcome` in response so it does not reappear
    /// on later launches.
    public mutating func dismiss() {
        isPresented = false
    }
}
