import DeskLayouterCore

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

/// User-facing consequences of Mission Control settings. Keeping the priority
/// here makes the disabling requirement testable independently of SwiftUI: the
/// separate-Spaces blocker always outranks the non-blocking positional warning.
public enum DisplaySettingsPresentation {
    public static func actionsAllowed(for topology: DisplayTopologySnapshot) -> Bool {
        topology.displaysHaveSeparateSpaces
    }

    public static func feedback(for topology: DisplayTopologySnapshot) -> EditorFeedback {
        if !topology.displaysHaveSeparateSpaces {
            return .info(
                "Displays have separate Spaces is off. Your board is preserved, and Apply and Arrange are disabled until you turn it on."
            )
        }
        if topology.automaticallyRearrangesSpaces {
            return .info(
                "Automatic Space rearrangement is enabled. Desktop numbers are positional and may change, but Apply and Arrange remain available."
            )
        }
        return .none
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
