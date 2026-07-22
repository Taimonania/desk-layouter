import DeskLayouterMacOS
import SwiftUI

/// Direction in which a custom tooltip expands from its control.
enum HoverTooltipEdge {
    case above
    case below
}

/// A compact, app-owned tooltip that appears after a predictable 200 ms hover.
/// Native `.help` timing is controlled by macOS and is substantially slower.
private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let edge: HoverTooltipEdge

    @Environment(\.hoverTooltipContainerWidth) private var containerWidth
    @State private var isPresented = false
    @State private var revealTask: Task<Void, Never>?
    @State private var tooltipWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .above ? .top : .bottom) {
                GeometryReader { proxy in
                    if isPresented {
                        tooltip
                            // GeometryReader uses top-leading placement by default;
                            // this frame restores the original centered overlay
                            // while still exposing the control's window position.
                            .frame(
                                width: proxy.size.width,
                                height: proxy.size.height,
                                alignment: edge == .above ? .top : .bottom
                            )
                            .offset(
                                x: horizontalOffset(controlCenterX: proxy.frame(
                                    in: .named(HoverTooltipCoordinateSpace.name)
                                ).midX),
                                y: edge == .above ? -32 : 32
                            )
                            // Let the first layout pass measure the tooltip before
                            // revealing it, avoiding one frame at its unclamped
                            // centered position near a window edge.
                            .opacity(tooltipWidth > 0 ? 1 : 0)
                    }
                }
            }
            .onPreferenceChange(HoverTooltipWidthKey.self) { tooltipWidth = $0 }
            .onHover(perform: updateHover)
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
                isPresented = false
            }
    }

    private func updateHover(_ hovering: Bool) {
        revealTask?.cancel()
        revealTask = nil

        guard hovering else {
            isPresented = false
            return
        }

        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            isPresented = true
        }
    }

    private var tooltip: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            // The shared policy moves the tooltip; it never wraps or truncates it.
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: HoverTooltipWidthKey.self, value: proxy.size.width)
                }
            }
            .transition(.opacity)
            .allowsHitTesting(false)
            .zIndex(1000)
    }

    private func horizontalOffset(controlCenterX: CGFloat) -> CGFloat {
        guard let containerWidth, tooltipWidth > 0 else { return 0 }
        let tooltipCenterX = EditorChromeLayout.tooltipCenterX(
            controlCenterX: controlCenterX,
            tooltipWidth: tooltipWidth,
            windowWidth: containerWidth
        )
        return tooltipCenterX - controlCenterX
    }
}

private enum HoverTooltipCoordinateSpace {
    static let name = "DeskLayouterHoverTooltipWindow"
}

private struct HoverTooltipContainerWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    var hoverTooltipContainerWidth: CGFloat? {
        get { self[HoverTooltipContainerWidthKey.self] }
        set { self[HoverTooltipContainerWidthKey.self] = newValue }
    }
}

private struct HoverTooltipWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HoverTooltipContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .environment(\.hoverTooltipContainerWidth, proxy.size.width)
                .coordinateSpace(name: HoverTooltipCoordinateSpace.name)
        }
    }
}

extension View {
    /// Establishes the window-wide coordinate space used by all descendant custom
    /// tooltips. Apply once to the root content view.
    func hoverTooltipContainer() -> some View {
        modifier(HoverTooltipContainerModifier())
    }

    func hoverTooltip(_ text: String, edge: HoverTooltipEdge = .below) -> some View {
        modifier(HoverTooltipModifier(text: text, edge: edge))
    }
}
