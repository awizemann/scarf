import Foundation

/// Where an effective per-bot setting actually comes from.
///
/// **The layering verdict (source-verified at Hermes v2026.8.31 / 0.21.0).**
/// A Hermes profile does **not** inherit the root profile's `config.yaml` at
/// runtime. `_load_config_impl` (`hermes_cli/config.py:3936-4080`) builds the
/// effective config from exactly three layers:
///
///   1. `DEFAULT_CONFIG` — Hermes' built-in schema defaults.
///   2. `get_config_path()` → `<HERMES_HOME>/config.yaml`, deep-merged on top.
///   3. the managed scope (`/etc/hermes/config.yaml`), merged last and winning
///      at the leaf.
///
/// `HERMES_HOME` under `hermes -p <bot>` is `<root>/profiles/<bot>`
/// (`_apply_profile_override`, `hermes_cli/main.py:521-724`, which rewrites the
/// env var *before* argparse and strips `-p` from argv). So layer 2 is the
/// **bot's own** file and the root's `config.yaml` is never consulted — profiles
/// are independent islands. The only relationship is a one-time COPY at
/// creation: `create_profile` clones config files with `--clone`, and a
/// clone-less create runs `_seed_model_config` (`profiles.py:773-805`), which
/// copies the active profile's `model:` block into the new file once. Editing
/// either afterwards never touches the other.
///
/// The UI consequence — and the reason this type exists — is that a bot's
/// unpinned key falls back to **Hermes' built-in default**, never to "whatever
/// the root profile says". Rendering the root's value as an inherited default
/// would be a lie, so ``BotAgentConfigService`` deliberately does not read the
/// root's `config.yaml` at all.
public enum BotConfigOrigin: Sendable, Equatable {
    /// The bot's own `config.yaml` sets this key: a real pin the user owns and
    /// can clear.
    case pinned
    /// The key is absent from the bot's `config.yaml`. Hermes resolves it from
    /// `DEFAULT_CONFIG` (possibly overridden by an administrator's managed
    /// scope, which Scarf cannot see from the file). **Not** inherited from the
    /// root profile.
    case hermesDefault
}

/// One typed setting read out of a bot's own `config.yaml`, carrying its
/// origin so the UI can say "pinned" or "Hermes default" honestly.
public struct BotConfigValue<Value: Sendable & Equatable>: Sendable, Equatable {
    /// The value written in the bot's `config.yaml`, or `nil` when unpinned.
    public let pinned: Value?

    public init(pinned: Value?) { self.pinned = pinned }

    public var origin: BotConfigOrigin { pinned == nil ? .hermesDefault : .pinned }
    public var isPinned: Bool { pinned != nil }
}

/// The enablement state of one MCP server in a bot's `config.yaml`.
///
/// Hermes reads `mcp_servers.<name>.enabled` with a `default=True`
/// (`agent/coding_context.py:711-729` via `tools_config._parse_enabled_flag`,
/// and `hermes_cli/mcp_config.py:734-737`), so an absent key means **enabled**.
/// The value is a plain scalar, which is why it is one of the few enablement
/// keys `hermes config set` can actually write.
public struct BotMCPServerState: Sendable, Equatable, Identifiable {
    public let name: String
    /// `nil` when the server exists but sets no `enabled:` key — enabled by
    /// Hermes' default, not by an explicit user choice.
    public let explicitlyEnabled: Bool?

    public var id: String { name }
    public var isEnabled: Bool { explicitlyEnabled ?? true }
    public var origin: BotConfigOrigin { explicitlyEnabled == nil ? .hermesDefault : .pinned }

    public init(name: String, explicitlyEnabled: Bool?) {
        self.name = name
        self.explicitlyEnabled = explicitlyEnabled
    }
}

/// Everything ``BotAgentConfigService`` can read about one bot's AGENT
/// configuration, in one snapshot taken from the bot's own profile home.
///
/// Every field here comes from `<root>/profiles/<name>/config.yaml` (or, for
/// `default`, the root home — which *is* that profile's home, not a fallback).
public struct BotAgentConfig: Sendable, Equatable {
    /// Canonical profile id.
    public let profileName: String
    /// `<profile_dir>/config.yaml` — the exact path that was read.
    public let configPath: String
    /// Whether that file exists. A brand-new profile created with `--no-skills`
    /// and no clone source can legitimately have none; `hermes config set`
    /// creates it on first write (`require_readable_config_before_write`
    /// returns `{}` for a missing file, `config.py:3633-3638`).
    public let configExists: Bool
    /// Whether that file could actually be read and parsed.
    ///
    /// **Audit fix.** `configExists && !configReadable` — an oversized,
    /// unreadable, or non-UTF-8 `config.yaml` — is NOT the same as "nothing is
    /// pinned", and rendering it that way would tell the user their bot runs on
    /// Hermes' defaults when it may be pinned to anything. Every
    /// ``BotConfigValue`` in that state is `nil` because Scarf could not look,
    /// not because the key is absent, so a UI must show "couldn't read
    /// `<configPath>`" rather than an origin. Writes are still safe — Hermes'
    /// own `require_readable_config_before_write` refuses to replace a file it
    /// cannot parse (`config.py:3612-3652`) — but they would be issued blind.
    public let configReadable: Bool

    /// `model.default` as written in the bot's file.
    public let model: BotConfigValue<String>
    /// `model.provider` as written in the bot's file.
    public let provider: BotConfigValue<String>
    /// `model.base_url`, when the bot pins a local/custom endpoint. Carried so
    /// `ModelPreflight`'s loopback auto-detect branch reaches the same verdict
    /// for a bot as for the root profile.
    public let modelBaseURL: String?

    /// `skills.disabled` — skill names the bot will not load.
    ///
    /// On hosts at `HermesCapabilities.hasEssentialHermesAgentSkill`
    /// (v0.20.6+) `hermes-agent` is dropped here even when the file still
    /// lists it, because Hermes drops it from every read of the list; showing
    /// it as disabled would claim the agent isn't loading a skill it is.
    public let disabledSkills: Set<String>

    /// `platform_toolsets.<platform>` — the enabled toolset names per platform,
    /// the key `hermes tools enable/disable --platform` writes
    /// (`hermes_cli/tools_config.py:2655-2656`, `_apply_toolset_change`).
    public let platformToolsets: [String: [String]]

    /// Every server under `mcp_servers:`, with its enablement origin.
    public let mcpServers: [BotMCPServerState]

    public init(
        profileName: String,
        configPath: String,
        configExists: Bool,
        configReadable: Bool,
        model: BotConfigValue<String>,
        provider: BotConfigValue<String>,
        modelBaseURL: String?,
        disabledSkills: Set<String>,
        platformToolsets: [String: [String]],
        mcpServers: [BotMCPServerState]
    ) {
        self.profileName = profileName
        self.configPath = configPath
        self.configExists = configExists
        self.configReadable = configReadable
        self.model = model
        self.provider = provider
        self.modelBaseURL = modelBaseURL
        self.disabledSkills = disabledSkills
        self.platformToolsets = platformToolsets
        self.mcpServers = mcpServers
    }

    /// Toolsets enabled for `platform`, or `nil` when the bot's file pins no
    /// list for it — in which case Hermes computes a default set at read time
    /// (`_get_platform_tools`), which Scarf must not pretend to know.
    /// True when the snapshot describes real on-disk state — either a file
    /// Scarf read, or a genuinely absent one. False means "we could not look".
    public var isTrustworthy: Bool { !configExists || configReadable }

    public func toolsets(forPlatform platform: String) -> [String]? {
        platformToolsets[platform]
    }
}
