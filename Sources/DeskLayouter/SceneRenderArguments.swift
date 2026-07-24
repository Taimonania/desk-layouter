/// Parses the app's hidden `--render-scene [key|all]` launch flag into a Scene
/// selection (issue #119). This is the pure decision at the front of the
/// Acceptance-Review render mode: given the process arguments, it says whether the
/// app was asked to render Scenes at all and, if so, which ones — without touching
/// AppKit, the Scene catalog, or the filesystem, so the selection logic (including
/// the "no flag → boot normally" case) is tested at its seam.
///
/// Lives in `DeskLayouterMacOS` (Foundation-only) purely so the executable's
/// render entry point can be exercised from the `main.swift` executable tests; the
/// AppKit rendering itself and the Scene catalog stay in the app target.
public enum SceneSelection: Equatable, Sendable {
    /// Render the whole catalog — a bare `--render-scene` or `--render-scene all`.
    case all
    /// Render a single Scene by its catalog key (validated against the catalog by
    /// the caller, which reports an unknown key).
    case key(String)
}

public enum SceneRenderArguments {
    /// The launch flag that switches the app into offscreen Scene-render mode.
    public static let flag = "--render-scene"

    /// The reserved value that selects the whole catalog.
    public static let allKeyword = "all"

    /// Decides what, if anything, to render from a process's arguments.
    ///
    /// - Returns `nil` when the flag is absent — the normal menu-bar launch, so the
    ///   render entry point returns `false` and the app boots unchanged.
    /// - Returns `.all` for a bare `--render-scene` (no following value, or the next
    ///   token is itself a flag) or an explicit `--render-scene all`.
    /// - Returns `.key(value)` for `--render-scene <value>`; the caller validates the
    ///   key against the catalog and reports an unknown one.
    public static func parse(_ arguments: [String]) -> SceneSelection? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }

        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else { return .all }

        let value = arguments[valueIndex]
        // A following token that is itself an option (e.g. `--render-scene --foo`)
        // is not a Scene key, so a bare flag still means "render everything".
        guard !value.hasPrefix("-") else { return .all }
        guard value != allKeyword else { return .all }
        return .key(value)
    }
}
