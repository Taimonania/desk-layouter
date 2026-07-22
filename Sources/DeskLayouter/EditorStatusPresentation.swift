/// Feedback produced by the latest editor action (Apply, Arrange, Preset edits,
/// and related board operations).
public enum EditorFeedback: Equatable, Sendable {
    case none
    case info(String)
    case success(String)
    case failure(String)

    public var message: String {
        switch self {
        case .none: ""
        case let .info(text), let .success(text), let .failure(text): text
        }
    }

    public var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// The content shown in the editor's one shared status area.
public struct EditorStatusPresentation: Equatable, Sendable {
    public let message: String
    public let isFailure: Bool

    public static func resolve(
        feedback: EditorFeedback,
        pendingChangeCount: Int,
        applyBlockedExplanation: String?,
        desktopCount: Int
    ) -> EditorStatusPresentation {
        if feedback != .none {
            return EditorStatusPresentation(
                message: feedback.message,
                isFailure: feedback.isFailure
            )
        }
        if let applyBlockedExplanation {
            return EditorStatusPresentation(
                message: applyBlockedExplanation,
                isFailure: false
            )
        }
        if desktopCount == 0 {
            return EditorStatusPresentation(
                message: "Apply is disabled because no Desktops are available on the active Display.",
                isFailure: false
            )
        }
        if pendingChangeCount > 0 {
            let noun = pendingChangeCount == 1 ? "change" : "changes"
            return EditorStatusPresentation(
                message: "\(pendingChangeCount) unapplied \(noun).",
                isFailure: false
            )
        }
        return EditorStatusPresentation(
            message: "No changes to apply.",
            isFailure: false
        )
    }
}
