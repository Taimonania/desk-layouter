/// The five segments the Layout editor's division control offers, in display
/// order: the four preset ``Division``s plus **Custom**, which stands for any 5–9
/// part split chosen from a separate dropdown. The segmented control iterates
/// these fixed segments rather than every ``Division`` case, so the four presets
/// read as before and every custom split collapses onto one "Custom" segment.
public enum DivisionSegment: Hashable, Sendable, CaseIterable {
    case full
    case halves
    case thirds
    case fourths
    case custom

    /// The segment that represents `division`: a preset maps to its own segment;
    /// any Custom split (5–9 parts) maps to `.custom`. This is how the editor lights
    /// the right segment when opening on an app already set to 5–9.
    public init(_ division: Division) {
        switch division {
        case .full: self = .full
        case .halves: self = .halves
        case .thirds: self = .thirds
        case .fourths: self = .fourths
        default: self = .custom
        }
    }

    /// The preset ``Division`` this segment selects, or `nil` for `.custom` — whose
    /// division depends on the separately chosen part count.
    public var presetDivision: Division? {
        switch self {
        case .full: .full
        case .halves: .halves
        case .thirds: .thirds
        case .fourths: .fourths
        case .custom: nil
        }
    }
}

extension Division {
    /// The segment that currently represents this division in the editor's control.
    public var segment: DivisionSegment { DivisionSegment(self) }

    /// The division produced by choosing `segment` in the editor's control while
    /// this division is the current one. A preset segment yields its division; the
    /// Custom segment keeps this division's part count when it is already Custom
    /// (5–9) and otherwise defaults to 5 — so switching in from a preset lands on 5
    /// while re-selecting Custom on an already-custom axis is a no-op.
    public func selecting(_ segment: DivisionSegment) -> Division {
        if let preset = segment.presetDivision { return preset }
        return isCustom ? self : .defaultCustom
    }
}
