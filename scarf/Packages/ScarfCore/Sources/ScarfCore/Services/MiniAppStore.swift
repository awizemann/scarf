import Foundation
#if canImport(os)
import os
#endif

/// Per-(project, mini-app) persisted key-value store backing
/// `scarf.store.get/set`, sandboxed to
/// `<project>/.scarf/miniapps/<id>/state.json`.
///
/// Values are stored as opaque JSON strings (the shim `JSON.stringify`s on
/// the way in and `JSON.parse`s on the way out), so the native side stays a
/// flat `[String: String]` and never interprets mini-app data. Transport-
/// based, so Mac + ScarfGo share it. Last-write-wins at the file level;
/// the WebKit message pump serializes a single mini-app's calls on the
/// main thread, so a mini-app never races itself.
public struct MiniAppStore: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppStore")
    #endif

    /// State files are small; anything past this is corrupt/hostile and is
    /// treated as empty.
    public static let maxBytes = 1 * 1024 * 1024

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// `<project>/.scarf/miniapps/<id>/state.json`.
    public nonisolated static func statePath(projectPath: String, miniAppId: String) -> String {
        MiniAppService.miniAppDir(forProjectPath: projectPath, id: miniAppId) + "/state.json"
    }

    /// The stored JSON string for `key`, or `nil` if unset / unreadable.
    public nonisolated func get(projectPath: String, miniAppId: String, key: String) -> String? {
        load(projectPath: projectPath, miniAppId: miniAppId)[key]
    }

    /// Set (or, with an empty key guard, reject) a key to a JSON string.
    /// Read-modify-write of the whole state file. Throws on I/O failure.
    public nonisolated func set(projectPath: String, miniAppId: String, key: String, value: String) throws {
        guard !key.isEmpty else { throw StoreError.invalidKey }
        var state = load(projectPath: projectPath, miniAppId: miniAppId)
        state[key] = value
        try write(state, projectPath: projectPath, miniAppId: miniAppId)
    }

    // MARK: - Private

    private nonisolated func load(projectPath: String, miniAppId: String) -> [String: String] {
        let path = Self.statePath(projectPath: projectPath, miniAppId: miniAppId)
        let transport = context.makeTransport()
        // One probe: both absent and unreadable already mean "empty
        // state" to this caller.
        guard let data = try? transport.readFile(path) else { return [:] }
        if data.count > Self.maxBytes {
            #if canImport(os)
            Self.logger.warning("mini-app state for \(miniAppId, privacy: .public) is \(data.count) bytes (cap \(Self.maxBytes)); treating as empty")
            #endif
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private nonisolated func write(_ state: [String: String], projectPath: String, miniAppId: String) throws {
        let dir = MiniAppService.miniAppDir(forProjectPath: projectPath, id: miniAppId)
        let transport = context.makeTransport()
        if !transport.fileExists(dir) {
            try transport.createDirectory(dir)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try transport.writeFile(
            Self.statePath(projectPath: projectPath, miniAppId: miniAppId),
            data: encoder.encode(state)
        )
    }

    public enum StoreError: Error, LocalizedError {
        case invalidKey
        public var errorDescription: String? {
            switch self {
            case .invalidKey: return "Mini-app store key must be non-empty."
            }
        }
    }
}
