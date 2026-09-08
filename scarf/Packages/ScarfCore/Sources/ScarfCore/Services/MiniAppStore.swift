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
///
/// **Unknown keys: preserved; unknown SHAPES: not** (declared per
/// `GuardedSidecarStore` section 4 — GW-F6 / audit DI L8). The model is
/// `[String: String]`, so every key the file holds survives a round trip
/// whoever wrote it — there is no typed struct to drop them. What does NOT
/// survive is a value that is not a JSON string: the decode fails, the bytes
/// are quarantined to `state.json.corrupt-<stamp>`, and the store rebuilds
/// from empty. That is the right trade for this file (mini-app state is
/// app-owned and re-creatable) and it is why the shim stringifies on the way
/// in — nothing Scarf writes can produce that shape.
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
        load(projectPath: projectPath, miniAppId: miniAppId).state[key]
    }

    /// Set (or, with an empty key guard, reject) a key to a JSON string.
    /// Read-modify-write of the whole state file. Throws on I/O failure.
    ///
    /// **Guarded (GW-E2c).** `load` used to be the textbook destroy shape —
    /// `try? readFile … ?? [:]` — and `set` published whatever came back.
    /// One dropped SSH round-trip on a healthy remote therefore replaced the
    /// mini-app's entire state with `{}`. The inspection that answered the
    /// read is now carried into the write (`GuardedJSONStore`): a
    /// stat-confirmed file that fails two reads REFUSES the write, and bytes
    /// that won't decode are quarantined to `state.json.corrupt-<stamp>` and
    /// rebuilt from empty — the sidecar half of the store's doctrine, which
    /// is right here because mini-app state is app-owned and re-creatable,
    /// unlike `projects.json`'s rows.
    public nonisolated func set(projectPath: String, miniAppId: String, key: String, value: String) throws {
        guard !key.isEmpty else { throw StoreError.invalidKey }
        let loaded = load(projectPath: projectPath, miniAppId: miniAppId)
        var state = loaded.state
        state[key] = value
        try write(
            state,
            projectPath: projectPath,
            miniAppId: miniAppId,
            after: loaded.inspection
        )
    }

    // MARK: - Private

    private nonisolated func load(
        projectPath: String, miniAppId: String
    ) -> (state: [String: String], inspection: GuardedJSONStore.Inspection) {
        let path = Self.statePath(projectPath: projectPath, miniAppId: miniAppId)
        let transport = context.makeTransport()
        // One read on the healthy path; the stat + retry probe below it runs
        // only after a read has already failed. Oversized and undecodable
        // both land in `.quarantined`, which still reads as empty state to
        // `get` — the same answer the old size/decode fallbacks gave — but
        // the bytes now survive in the quarantine copy.
        let (inspection, decoded) = GuardedJSONStore(transport: transport, label: "state.json")
            .inspectDecoding([String: String].self, at: path, maxBytes: Self.maxBytes)
        #if canImport(os)
        if case .quarantined(let copy) = inspection.state {
            Self.logger.warning("mini-app state for \(miniAppId, privacy: .public) was unusable; quarantined to \(copy, privacy: .public) and rebuilding")
        }
        #endif
        return (decoded ?? [:], inspection)
    }

    private nonisolated func write(
        _ state: [String: String],
        projectPath: String,
        miniAppId: String,
        after inspection: GuardedJSONStore.Inspection
    ) throws {
        let dir = MiniAppService.miniAppDir(forProjectPath: projectPath, id: miniAppId)
        let transport = context.makeTransport()
        // `createDirectory` is `mkdir -p` on every transport, so the
        // `fileExists` gate in front of it bought nothing and cost a full
        // SSH round-trip on the JS-callable `scarf.store.set` path (GW-F6 /
        // audit PERF M2). It was also the create-if-missing INFERENCE shape
        // in miniature: one dropped probe and the mkdir ran anyway.
        try transport.createDirectory(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try GuardedJSONStore(transport: transport, label: "state.json").write(
            try encoder.encode(state),
            to: Self.statePath(projectPath: projectPath, miniAppId: miniAppId),
            after: inspection
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
