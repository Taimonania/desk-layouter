import DeskLayouterCore
import Foundation

/// Reads and writes the user's ``PresetLibrary`` as JSON on disk.
///
/// This is the thin filesystem boundary around the pure ``PresetLibrary`` model,
/// mirroring `BoardStateStore`/`ConfigurationStore`: the library lives under
/// `~/Library/Application Support/DeskLayouter/presets.json`, separate from the
/// working board so a Preset save never rewrites the board file and vice versa.
///
/// Loading is tolerant: a missing file means no Presets have been saved yet and
/// yields an empty library, and decoding routes through the tolerant
/// `PresetLibrarySerialization`, so a partial or forward-written file loads what
/// it can rather than destroying the ability to start fresh.
public final class PresetLibraryStore {
    private static let subdirectoryName = "DeskLayouter"
    private static let fileName = "presets.json"

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// The store backed by the app-specific subdirectory of Application Support.
    /// Resolving the path creates no directories.
    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> PresetLibraryStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return PresetLibraryStore(fileURL: libraryURL(under: base), fileManager: fileManager)
    }

    /// A best-effort store for contexts that cannot surface a thrown error (such
    /// as `EditorModel`'s initializer). Falls back to a temporary-directory path
    /// if Application Support cannot be resolved, so the editor still launches.
    public static var `default`: PresetLibraryStore {
        if let store = try? applicationSupport() {
            return store
        }
        return PresetLibraryStore(
            fileURL: libraryURL(under: FileManager.default.temporaryDirectory)
        )
    }

    private static func libraryURL(under base: URL) -> URL {
        base
            .appendingPathComponent(subdirectoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads the saved Preset library. A missing file is not an error: it means
    /// nothing has been saved yet, so an empty library is returned.
    public func load() throws -> PresetLibrary {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return PresetLibrary()
        }
        let data = try Data(contentsOf: fileURL)
        return try PresetLibrarySerialization.decode(from: data)
    }

    /// Atomically writes the Preset library to disk, creating the containing
    /// directory if needed.
    public func save(_ library: PresetLibrary) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PresetLibrarySerialization.encode(library)
        try data.write(to: fileURL, options: .atomic)
    }
}
