import DeskLayouterCore
import Foundation

/// Reads and writes the Desk Layouter configuration as JSON on disk.
///
/// This is the thin filesystem boundary around the pure source-of-truth model:
/// the config lives under `~/Library/Application Support/DeskLayouter/`. The
/// store only ever writes what it is given from user actions — it never reads
/// the macOS `com.apple.spaces` store, so unmanaged system bindings can never be
/// imported into the app's source of truth.
public final class ConfigurationStore {
    private static let subdirectoryName = "DeskLayouter"
    private static let fileName = "configuration.json"

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// The store backed by the app-specific subdirectory of Application Support.
    ///
    /// Resolving the path does not create any directories — `save(_:)` creates
    /// the containing directory when it first writes, so merely constructing the
    /// store has no filesystem side effects.
    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> ConfigurationStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return ConfigurationStore(fileURL: configurationURL(under: base), fileManager: fileManager)
    }

    /// A best-effort store for contexts that cannot surface a thrown error (such
    /// as `EditorModel`'s initializer). Falls back to a temporary-directory path
    /// if Application Support cannot be resolved, so the editor still launches.
    public static var `default`: ConfigurationStore {
        if let store = try? applicationSupport() {
            return store
        }
        return ConfigurationStore(
            fileURL: configurationURL(under: FileManager.default.temporaryDirectory)
        )
    }

    private static func configurationURL(under base: URL) -> URL {
        base
            .appendingPathComponent(subdirectoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads the saved configuration. A missing file is not an error: it means
    /// nothing has been saved yet, so an empty configuration is returned.
    public func load() throws -> DeskLayouterConfiguration {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return DeskLayouterConfiguration()
        }
        let data = try Data(contentsOf: fileURL)
        return try ConfigurationSerialization.decode(from: data)
    }

    /// Atomically writes the configuration to disk, creating the containing
    /// directory if needed.
    public func save(_ configuration: DeskLayouterConfiguration) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try ConfigurationSerialization.encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }
}
