import Foundation

/// First-class, fleet-aware record of a Scarf project — the object the
/// Phase-1 "make projects amazing" design promotes Project to.
///
/// Today a "project" is implicit: its identity is smeared across the
/// session-attribution sidecar, the AGENTS.md managed block, the
/// template lock, a Kanban tenant, cron tags, a model preset, a
/// MEMORY.md marker, and Keychain refs — each owned by a different
/// service. `ScarfProject` is the single object that *references*
/// (never duplicates) those facets so one record can answer "what is
/// this project, across the hosts it lives on?"
///
/// **Canonical store.** The record is repo-resident at
/// `<rootPath>/.scarf/project.json` (portable, versionable, travels
/// with the repo — same placement as `template.lock.json`). The
/// existing per-server registry (`ProjectRegistry`/`ProjectEntry` at
/// `~/.hermes/scarf/projects.json`) is the fast-list index; it carries
/// the stable `id` so the canonical record can be located without
/// walking the filesystem. `ProjectStore` owns both sides.
///
/// **Bindings are references, not copies.** `modelPresetId` points at a
/// `ModelPreset` record; `board` is a Kanban tenant/board slug;
/// `cronJobIds` indexes jobs tagged `[proj:<id>]`; `secretsScope`
/// carries Keychain ref NAMES only (never values — the SECRET-SAFE
/// invariant). The AGENTS.md managed block is *rendered from* this
/// object (`ProjectAgentContextService.renderBlock(for:)`), so the
/// block stays a projection of the structured truth.
///
/// **Codable is lenient + additive.** Decoding fills missing keys with
/// defaults (empty collections, `nil`, current schema version) so a
/// minimal `{ "id", "name", "rootPath" }` record decodes and so future
/// fields can be added without invalidating records written by this
/// release. Dates serialize as ISO-8601 strings, self-contained — no
/// reliance on the decoder's `dateDecodingStrategy`.
public struct ScarfProject: Codable, Sendable, Identifiable, Hashable {

    /// Bump when the on-disk shape changes in a way older readers must
    /// notice. Additive field changes don't require a bump (lenient
    /// decoding covers them); a bump is for semantic migrations.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Stable identity. Survives renames and moves; the registry index
    /// and the `[proj:<id>]` cron tag both key on it. Minted once
    /// (scaffold time, or first migration of a legacy project) and
    /// never regenerated.
    public let id: UUID

    public var name: String

    /// Absolute path on *this* host. The same logical project can be
    /// materialized at different paths on different servers — see
    /// `hostBindings`.
    public var rootPath: String

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Bindings (references into existing stores)

    /// `ModelPreset` UUID-as-string, applied at session boot via
    /// `session/set_model`. `nil` → inherit the global default.
    public var modelPresetId: String?

    /// Hermes toolset names scoped to this project (web, browser, …).
    /// **DEFERRED for Milestone 1** — always empty. The ACP adapter
    /// hardcodes `enabled_toolsets=["hermes-acp"]` and ignores the
    /// `hermes acp -t/--toolsets` flag, so there is no per-session
    /// enforcement seam yet. Unblocks on upstream hermes-agent#45958
    /// (`SessionManager(default_toolsets)` + per-session `toolsets`).
    public var scopedToolsets: [String]

    /// Skill / bundle names scoped to this project. **DEFERRED for
    /// Milestone 1** — always empty (same enforcement gap as
    /// `scopedToolsets`).
    public var scopedSkills: [String]

    /// Kanban board slug (v0.16 multi-board) or tenant filter — the
    /// project's task namespace against the one global `kanban.db`.
    /// Mirrors `KanbanTenantResolver`'s `scarf:<slug>` convention.
    public var board: String?

    /// Cron job ids tagged `[proj:<id>]` (mirrors the `[tmpl:<id>]`
    /// convention). The index — uninstall removes via
    /// `hermes cron remove`.
    public var cronJobIds: [String]

    /// MEMORY.md marker id, when the project owns a memory block.
    public var memoryNamespace: String?

    /// Keychain ref NAMES only — **never values** (SECRET-SAFE). These
    /// are the `config.json` keys whose values are `keychain://…` refs.
    public var secretsScope: [String]

    /// Path to `template.lock.json` when the project was template-
    /// installed; `nil` for hand-scaffolded / bare projects.
    public var templateLockRef: String?

    // MARK: - Fleet

    /// Where this stable id is materialized. One entry per host the
    /// project is live on; the portfolio view groups same-`id`
    /// projects across servers via this list. Milestone 1 maintains a
    /// single binding for the current server.
    public var hostBindings: [HostBinding]

    // MARK: - Mini-apps (Milestone 2 bridge field)

    /// Registry of mini-apps belonging to this project — the portable
    /// "what's installed" list. Each entry locates a mini-app dir at
    /// `<rootPath>/.scarf/miniapps/<id>/`; the full `MiniAppManifest`
    /// (and the user's per-machine permission grants) are loaded
    /// separately, NOT stored here. Granted permissions deliberately do
    /// NOT travel in this portable record — a clone must re-approve
    /// untrusted (especially agent-generated) web content for itself.
    public var miniApps: [MiniAppRef]

    // MARK: - Unknown keys

    /// Every top-level key in `project.json` that this build does not
    /// model, carried verbatim through decode → edit → encode.
    ///
    /// **Why this file most of all (P8 DI-H2).** `project.json` is the ONE
    /// record documented as portable — it travels with the repo, is
    /// versioned alongside it, and is read by other Scarf builds and
    /// written by agents. Yet every save rewrote it wholesale from this
    /// model, so any key the model didn't declare was deleted: a newer
    /// Scarf's field erased by an older build opening the same checkout, an
    /// agent's own annotation erased by a rename, a future binding erased
    /// by a derive-and-save. `ProjectEntry` and `ProjectRegistry` got this
    /// contract in 7bc27c9 for exactly the same reason; the portable record
    /// had the weaker guarantee, which is backwards.
    ///
    /// Excluded from `Equatable`/`Hashable` (see below) so an unknown key
    /// appearing can never disturb selection or set membership.
    public var extra: [String: JSONValue]

    /// One host's materialization of a project — the fleet dimension
    /// that a per-gateway client structurally cannot offer.
    public struct HostBinding: Codable, Sendable, Hashable {
        /// `ServerContext.id` as a string (the well-known local id, or
        /// a registered remote's UUID).
        public var serverId: String
        /// Absolute path on that host.
        public var rootPath: String
        public var materializedAt: Date

        public init(serverId: String, rootPath: String, materializedAt: Date) {
            self.serverId = serverId
            self.rootPath = rootPath
            self.materializedAt = materializedAt
        }
    }

    /// A mini-app registered to this project. Lightweight — the full
    /// manifest lives in `<rootPath>/.scarf/miniapps/<id>/miniapp.json`
    /// (loaded via `MiniAppService`); this carries only the id (which
    /// locates the dir) and the agent-generated provenance flag.
    public struct MiniAppRef: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        /// Mirrors `MiniAppManifest.generated` — `true` for agent-written
        /// mini-apps, which get stricter trust defaults.
        public var generated: Bool

        public init(id: String, generated: Bool = false) {
            self.id = id
            self.generated = generated
        }

        private enum CodingKeys: String, CodingKey { case id, generated }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.generated = try c.decodeIfPresent(Bool.self, forKey: .generated) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(generated, forKey: .generated)
        }
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        schemaVersion: Int = ScarfProject.currentSchemaVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        modelPresetId: String? = nil,
        scopedToolsets: [String] = [],
        scopedSkills: [String] = [],
        board: String? = nil,
        cronJobIds: [String] = [],
        memoryNamespace: String? = nil,
        secretsScope: [String] = [],
        templateLockRef: String? = nil,
        hostBindings: [HostBinding] = [],
        miniApps: [MiniAppRef] = [],
        extra: [String: JSONValue] = [:]
    ) {
        self.extra = extra
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelPresetId = modelPresetId
        self.scopedToolsets = scopedToolsets
        self.scopedSkills = scopedSkills
        self.board = board
        self.cronJobIds = cronJobIds
        self.memoryNamespace = memoryNamespace
        self.secretsScope = secretsScope
        self.templateLockRef = templateLockRef
        self.hostBindings = hostBindings
        self.miniApps = miniApps
    }

    // MARK: - Codable (lenient + additive; ISO-8601 dates)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, name, rootPath, createdAt, updatedAt
        case modelPresetId, scopedToolsets, scopedSkills, board
        case cronJobIds, memoryNamespace, secretsScope, templateLockRef
        case hostBindings, miniApps
    }

    // MARK: - Equatable / Hashable (declared fields only, sans `extra`)
    //
    // Hand-written to EXCLUDE `extra`, mirroring `ProjectEntry`: `JSONValue`
    // is `Equatable` but not `Hashable`, and more importantly a key this
    // build doesn't understand must not change a record's identity.

    public static func == (lhs: ScarfProject, rhs: ScarfProject) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.rootPath == rhs.rootPath
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.modelPresetId == rhs.modelPresetId
            && lhs.scopedToolsets == rhs.scopedToolsets
            && lhs.scopedSkills == rhs.scopedSkills
            && lhs.board == rhs.board
            && lhs.cronJobIds == rhs.cronJobIds
            && lhs.memoryNamespace == rhs.memoryNamespace
            && lhs.secretsScope == rhs.secretsScope
            && lhs.templateLockRef == rhs.templateLockRef
            && lhs.hostBindings == rhs.hostBindings
            && lhs.miniApps == rhs.miniApps
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(rootPath)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id`, `name`, `rootPath` are the minimal record. Everything
        // else defaults so older / partial records decode cleanly.
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.rootPath = try c.decode(String.self, forKey: .rootPath)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ScarfProject.currentSchemaVersion
        self.createdAt = Self.decodeDate(c, .createdAt) ?? Date()
        self.updatedAt = Self.decodeDate(c, .updatedAt) ?? Date()
        self.modelPresetId = try c.decodeIfPresent(String.self, forKey: .modelPresetId)
        self.scopedToolsets = try c.decodeIfPresent([String].self, forKey: .scopedToolsets) ?? []
        self.scopedSkills = try c.decodeIfPresent([String].self, forKey: .scopedSkills) ?? []
        self.board = try c.decodeIfPresent(String.self, forKey: .board)
        self.cronJobIds = try c.decodeIfPresent([String].self, forKey: .cronJobIds) ?? []
        self.memoryNamespace = try c.decodeIfPresent(String.self, forKey: .memoryNamespace)
        self.secretsScope = try c.decodeIfPresent([String].self, forKey: .secretsScope) ?? []
        self.templateLockRef = try c.decodeIfPresent(String.self, forKey: .templateLockRef)
        self.hostBindings = try c.decodeIfPresent([HostBinding].self, forKey: .hostBindings) ?? []
        self.miniApps = try c.decodeIfPresent([MiniAppRef].self, forKey: .miniApps) ?? []

        // Sweep up every key this model doesn't declare — explicit nulls
        // included — so `encode(to:)` puts them back untouched.
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        if let raw = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in raw.allKeys where !known.contains(key.stringValue) {
                if let value = try? raw.decode(JSONValue.self, forKey: key) {
                    extras[key.stringValue] = value
                }
            }
        }
        self.extra = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(Self.iso8601.string(from: createdAt), forKey: .createdAt)
        try c.encode(Self.iso8601.string(from: updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(modelPresetId, forKey: .modelPresetId)
        try c.encode(scopedToolsets, forKey: .scopedToolsets)
        try c.encode(scopedSkills, forKey: .scopedSkills)
        try c.encodeIfPresent(board, forKey: .board)
        try c.encode(cronJobIds, forKey: .cronJobIds)
        try c.encodeIfPresent(memoryNamespace, forKey: .memoryNamespace)
        try c.encode(secretsScope, forKey: .secretsScope)
        try c.encodeIfPresent(templateLockRef, forKey: .templateLockRef)
        try c.encode(hostBindings, forKey: .hostBindings)
        try c.encode(miniApps, forKey: .miniApps)

        // Unknown keys go back last. They cannot collide with the declared
        // ones (filtered against exactly this key set on the way in).
        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try raw.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }

    /// Shared ISO-8601 formatter for the date fields. `static let` so
    /// the (relatively expensive) formatter is built once. `internal`
    /// (not `private`) so the sibling `HostBinding` Codable extension
    /// reuses the same instance.
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    /// Decode an ISO-8601 date string at `key`, tolerating absence. A
    /// present-but-unparseable string also yields `nil` so a hand-edited
    /// record never hard-fails the whole decode.
    private static func decodeDate(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Date? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return iso8601.date(from: s)
    }
}

// MARK: - HostBinding Codable (ISO-8601 date)

extension ScarfProject.HostBinding {
    private enum CodingKeys: String, CodingKey {
        case serverId, rootPath, materializedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = try c.decode(String.self, forKey: .serverId)
        self.rootPath = try c.decode(String.self, forKey: .rootPath)
        if let s = try? c.decodeIfPresent(String.self, forKey: .materializedAt),
           let d = ScarfProject.iso8601.date(from: s) {
            self.materializedAt = d
        } else {
            self.materializedAt = Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serverId, forKey: .serverId)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(ScarfProject.iso8601.string(from: materializedAt), forKey: .materializedAt)
    }
}
