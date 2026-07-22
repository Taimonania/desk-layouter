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

    @State private var isPresented = false
    @State private var revealTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .above ? .top : .bottom) {
                if isPresented {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.25))
                        )
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .offset(y: edge == .above ? -32 : 32)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(1000)
                }
            }
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
}

extension View {
    func hoverTooltip(_ text: String, edge: HoverTooltipEdge = .below) -> some View {
        modifier(HoverTooltipModifier(text: text, edge: edge))
    }
}
