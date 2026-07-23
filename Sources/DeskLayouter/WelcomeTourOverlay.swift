import DeskLayouterMacOS
import SwiftUI

/// Collects the on-screen bounds of the live controls the Welcome tour spotlights,
/// keyed by target. Real controls tag themselves with `.welcomeAnchor(_:)`; the
/// root resolves the anchors in its own coordinate space to draw the spotlight
/// cut-outs and rings (issue #72).
struct WelcomeAnchorKey: PreferenceKey {
    static let defaultValue: [WelcomeSpotlightTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [WelcomeSpotlightTarget: Anchor<CGRect>],
        nextValue: () -> [WelcomeSpotlightTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tags this view as the live control the Welcome tour spotlights for `target`,
    /// publishing its bounds so the overlay can dim around it and ring it.
    func welcomeAnchor(_ target: WelcomeSpotlightTarget) -> some View {
        anchorPreference(key: WelcomeAnchorKey.self, value: .bounds) { [target: $0] }
    }

    /// Masks `self` with the *inverse* of `mask` — everything except the masked
    /// shapes is kept. Used to punch spotlight holes in the dimming layer.
    fileprivate func reverseMask<Mask: View>(
        @ViewBuilder _ mask: () -> Mask
    ) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

/// The live Welcome-tour overlay: a dimming layer that darkens the board, cut-outs
/// and accent rings around the current step's spotlighted controls, and a callout
/// card with the step copy, progress dots, and Back / Skip / Next / Done controls
/// (issue #72). The final step also recreates an app card with its Layout icon
/// highlighted, since the board is empty on first run.
///
/// This view owns presentation only; step and navigation logic live in the tested
/// `WelcomeTour` seam, and the root drives it through the injected closures.
struct WelcomeTourOverlay: View {
    let tour: WelcomeTour
    /// Bounds (in the overlay's coordinate space) of the controls the current step
    /// spotlights, already resolved from the collected anchors.
    let spotlightFrames: [CGRect]

    let onNext: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void
    let onFinish: () -> Void

    private static let spotlightPadding: CGFloat = 10
    private static let spotlightCornerRadius: CGFloat = 10
    private static let calloutWidth: CGFloat = 430

    var body: some View {
        ZStack {
            dimmingLayer
            spotlightRings
            calloutLayer
        }
        // Block interaction with the board underneath: during the tour the callout
        // controls drive everything, so live clicks never fall through the dim.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome tour")
    }

    // MARK: - Dimming + spotlight

    private var dimmingLayer: some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .reverseMask {
                ForEach(Array(spotlightFrames.enumerated()), id: \.offset) { _, frame in
                    RoundedRectangle(cornerRadius: Self.spotlightCornerRadius)
                        .frame(
                            width: frame.width + Self.spotlightPadding * 2,
                            height: frame.height + Self.spotlightPadding * 2
                        )
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .ignoresSafeArea()
    }

    private var spotlightRings: some View {
        ForEach(Array(spotlightFrames.enumerated()), id: \.offset) { _, frame in
            RoundedRectangle(cornerRadius: Self.spotlightCornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(
                    width: frame.width + Self.spotlightPadding * 2,
                    height: frame.height + Self.spotlightPadding * 2
                )
                .position(x: frame.midX, y: frame.midY)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Callout

    /// Every page uses the same centered card width, but the card hugs its content
    /// vertically so short steps get a short card instead of a mostly-empty box that
    /// can cover the very controls it points at (issue #110). The bottom navigation
    /// stays stable while spotlight targets change behind it.
    private var calloutLayer: some View {
        callout
            .frame(width: Self.calloutWidth)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
            .padding(24)
    }

    private var callout: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tour.currentStep.title)
                .font(.title3)
                .fontWeight(.semibold)

            if tour.currentStep.showsSampleCard {
                WelcomeSampleCard()
            }

            Text(tour.currentStep.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if !tour.isFirstStep {
                    Button("Back") { onBack() }
                        .accessibilityLabel("Back to the previous step")
                        .frame(width: 52)
                } else {
                    // Reserve Back's exact slot without exposing a Back control on
                    // step 1, so the rest of the row never shifts.
                    Button("Back") {}
                        .frame(width: 52)
                        .hidden()
                }

                Text("Step \(tour.stepIndex + 1) of \(tour.stepCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                progressDots
                Spacer(minLength: 8)

                Button("Skip") { onSkip() }
                    .accessibilityLabel("Skip the Welcome tour")
                // The tour's controls are click-driven and carry no keyboard
                // shortcut: the live Apply button behind the dim also owns
                // `.defaultAction`, so giving Next/Done the same shortcut would make
                // Return ambiguous — and could fire Apply (which moves real windows)
                // from within the tour. Leaving them shortcut-free keeps the tour's
                // Back / Skip / Next / Done set uniform and collision-free.
                if tour.isLastStep {
                    Button("Done") { onFinish() }
                        .accessibilityLabel("Finish the Welcome tour")
                        .frame(width: 56)
                } else {
                    Button("Next") { onNext() }
                        .accessibilityLabel("Next step")
                        .frame(width: 56)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tour.currentStep.title). Step \(tour.stepIndex + 1) of \(tour.stepCount).")
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<tour.stepCount, id: \.self) { index in
                Circle()
                    .fill(index == tour.stepIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(tour.stepIndex + 1) of \(tour.stepCount)")
    }
}

/// A faithful, static recreation of a board app card with its Layout icon
/// highlighted (issue #72). Shown on the final tour step because the board is
/// empty on first run, so there is no live card to anchor to. It mirrors the real
/// `appCard`'s structure — drag handle, icon, name, Layout icon, remove control —
/// so the tour points at a card the user will recognize once they add apps.
struct WelcomeSampleCard: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
            Text("Example App")
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(Color.accentColor)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example app card with its Layout icon highlighted")
    }
}
