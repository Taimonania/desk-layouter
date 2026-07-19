import DeskLayouterCore
import Foundation

/// Reads and writes the board's pending-state (working configuration plus the
/// applied baseline) as JSON on disk.
///
/// This is the thin filesystem boundary around the pure ``BoardState`` model,
/// mirroring `ConfigurationStore`: the state lives under
/// `~/Library/Application Support/DeskLayouter/board-state.json`. It only ever
/// writes what user actions produce — it never reads the macOS
/// `com.apple.spaces` store, so unmanaged system bindings can never enter the
/// app's source of truth.
///
/// The first time it loads on a machine that has only a legacy
/// `configuration.json` (written before pending-state tracking existed), it
/// migrates that configuration in as an already-applied — therefore clean —
/// board, so no previously saved Assignments are lost and nothing is falsely
/// reported as pending.
public final class BoardStateStore {
    private static let subdirectoryName = "DeskLayouter"
    private static let fileName = "board-state.json"

    private let fileURL: URL
    private let legacyConfigurationStore: ConfigurationStore?
    private let fileManager: FileManager

    public init(
        fileURL: URL,
        legacyConfigurationStore: ConfigurationStore? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.legacyConfigurationStore = legacyConfigurationStore
        self.fileManager = fileManager
    }

    /// The store backed by the app-specific subdirectory of Application Support,
    /// wired to the legacy configuration store in the same directory for
    /// one-time migration. Resolving the path creates no directories.
    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> BoardStateStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directory = base.appendingPathComponent(subdirectoryName, isDirectory: true)
        return BoardStateStore(
            fileURL: directory.appendingPathComponent(fileName, isDirectory: false),
            legacyConfigurationStore: ConfigurationStore(
                fileURL: directory.appendingPathComponent("configuration.json", isDirectory: false),
                fileManager: fileManager
            ),
            fileManager: fileManager
        )
    }

    /// A best-effort store for contexts that cannot surface a thrown error (such
    /// as `EditorModel`'s initializer). Falls back to a temporary-directory path
    /// if Application Support cannot be resolved, so the editor still launches.
    public static var `default`: BoardStateStore {
        if let store = try? applicationSupport() {
            return store
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(subdirectoryName, isDirectory: true)
        return BoardStateStore(
            fileURL: directory.appendingPathComponent(fileName, isDirectory: false)
        )
    }

    /// Loads the saved board state. When no state file exists yet it migrates a
    /// legacy configuration (as a clean, already-applied board) if one is
    /// present, and otherwise returns an empty board.
    public func load() throws -> BoardState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            if let legacyConfiguration = try? legacyConfigurationStore?.load(),
               !legacyConfiguration.managedApplications.isEmpty {
                return BoardState(configuration: legacyConfiguration)
            }
            return BoardState()
        }
        let data = try Data(contentsOf: fileURL)
        return try BoardStateSerialization.decode(from: data)
    }

    /// Atomically writes the board state to disk, creating the containing
    /// directory if needed.
    public func save(_ boardState: BoardState) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try BoardStateSerialization.encode(boardState)
        try data.write(to: fileURL, options: .atomic)
    }
}
