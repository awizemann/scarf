import Foundation

/// The Bot Mode **agent-configuration** layer: reading and writing one bot's
/// model pin, toolset/MCP enablement, disabled skills, and `SOUL.md` — always
/// against that bot's own profile home, never the root.
///
/// Sibling of ``BotsService`` rather than an extension of it: `BotsService`
/// owns *identity* (`profile.yaml`, avatars, profile lifecycle) and is built
/// from a transport + a `HermesPathSet`; this type owns *agent config* and is
/// built from a `ServerContext`, because every read and write here has to be
/// re-pointed per bot and `ServerContext.pinnedToProfile(_:)` is the seam
/// Phase A fixed for exactly that (see its doc comment: `nil`/`""`/`"default"`
/// /invalid all mean the **root** home, never "unchanged").
///
/// ## Read/write split, and why
///
/// **Reads go to the file.** `<profile_dir>/config.yaml` is read directly
/// through the transport and parsed with `HermesYAML`/`HermesConfig`, matching
/// how the root-profile features already read (`SkillsViewModel
/// .readDisabledSkillNames`, `ToolsViewModel.loadPlatforms`,
/// `HermesConfigReader.readRawConfig`). There is also a correctness reason
/// beyond consistency: `hermes config get` prints the **effective** value
/// (`get_config_value` → `load_config()`, `hermes_cli/config.py:6000-6012`),
/// which folds in `DEFAULT_CONFIG` and the managed overlay and gives the
/// caller no way to tell a user pin from a built-in default. Scarf's whole UI
/// story here is "pinned vs default", so the raw file is the only honest
/// source. See ``BotConfigOrigin`` for the full layering verdict.
///
/// **Writes go to the CLI**, `hermes -p <bot> <verb>`, mirroring the
/// root-profile path one-for-one (`HermesFileService.saveModelConfig`,
/// `SettingsViewModel.applyConfigWrite`, `ToolsViewModel.toggleTool`). Hermes'
/// writers do work Scarf must not reimplement: atomic replace with owner/mode
/// preservation, the fail-closed `require_readable_config_before_write` guard,
/// managed-scope rejection, `.env` routing for credential-shaped keys, and the
/// YAML 1.1 quoting fix for values like `off`.
///
/// ## `-p` composes with every verb used here
///
/// `_apply_profile_override()` (`hermes_cli/main.py:521-724`) scans raw `argv`
/// for `-p`/`--profile` **before** argparse, sets `HERMES_HOME` to the resolved
/// profile directory, and strips the flag from `sys.argv`. It is not attached
/// to any subcommand, and `-p` is not claimed as a short flag by any
/// subparser at the audited tag (`grep '"-p"' hermes_cli/subcommands/*.py`
/// matches nothing; only `_parser.py:23` declares it). So `config`, `tools`,
/// `skills` and `mcp` all take it the same way `acp` and `chat` do. Two carve-
/// outs, neither of which this service touches: argv after a bare `--`, and
/// the `hermes mcp add … --args <child argv>` passthrough region.
///
/// `-p` is passed on **every** invocation, including `default`. That is not
/// redundant: without it, step 2 of the override follows the host's sticky
/// `~/.hermes/active_profile`, so a local spawn for the *default* bot on a
/// machine whose active profile is `work` would write into `work`'s
/// `config.yaml`. `LocalTransport` — unlike `SSHTransport`, which emits a
/// `HERMES_HOME=` assignment from the pinned context — sets no `HERMES_HOME`,
/// which makes the explicit flag the only thing standing between the default
/// bot and the wrong profile.
///
/// All entry points do blocking transport I/O — call off the MainActor.
public struct BotAgentConfigService: Sendable {

    /// The window's context. Never used for I/O directly: every operation goes
    /// through ``context(forProfile:)``, which root-normalizes and re-pins.
    private let baseContext: ServerContext
    private let capabilities: HermesCapabilities

    /// Ceiling on a single `config.yaml` read. Hermes' own config is a
    /// hand-edited settings file; 1MB is far past any real one and bounds what
    /// a corrupt or hostile file can pull across an SSH channel.
    public static let maxConfigYAMLBytes = 1_048_576

    /// Ceiling on a `SOUL.md` read/write. `SOUL.md` is the agent's identity
    /// prompt — Hermes injects it as slot #1 of the system prompt and
    /// truncates it against the model's context window at build time
    /// (`agent/prompt_builder.py:2196-2229`), so there is no on-disk cap to
    /// mirror. 256KB is orders of magnitude above a usable identity prompt and
    /// keeps an editor buffer bounded.
    public static let maxSoulBytes = 262_144

    public init(context: ServerContext, capabilities: HermesCapabilities) {
        self.baseContext = context
        self.capabilities = capabilities
    }

    // MARK: - Addressing

    /// The context pinned to one bot's profile home.
    ///
    /// Root-normalizes first (see `pinnedToProfile`), so this is correct even
    /// when the window is already scoped to some other profile (#126).
    public func context(forProfile name: String) -> ServerContext {
        baseContext.pinnedToProfile(name)
    }

    /// `<profile_dir>/config.yaml`.
    public func configPath(forProfile name: String) -> String {
        context(forProfile: name).paths.configYAML
    }

    /// `<profile_dir>/SOUL.md`.
    ///
    /// Verified at the audited tag: the agent loads its identity from
    /// `get_hermes_home() / "SOUL.md"` (`agent/prompt_builder.py:2215`), and
    /// the Bot Mode probe hashes `<profile_dir>/SOUL.md` as part of a bot's
    /// capability fingerprint (`tools/bot_mode_probe.py:359`). There is no
    /// per-bot SOUL location other than the profile home.
    public func soulPath(forProfile name: String) -> String {
        context(forProfile: name).paths.soulMD
    }

    /// The argv prefix that scopes an invocation to `name`. Always present.
    static func profileFlag(_ name: String) -> [String] {
        // `normalize` maps default/empty/invalid to nil; the flag still gets
        // the literal `default`, which `resolve_profile_env` resolves to the
        // ROOT home (`profiles.py:2513-2514`). Passing it beats omitting `-p`,
        // which would let the host's sticky `active_profile` decide.
        ["-p", HermesProfileScope.normalize(name) ?? HermesProfileScope.defaultProfileName]
    }

    // MARK: - Reading

    /// Snapshot one bot's agent configuration from its own `config.yaml`.
    ///
    /// Never throws for a missing or malformed file: a bot with no config
    /// renders as "everything at Hermes' defaults", which is exactly what
    /// Hermes will do with it. Throws only when the profile id is one Scarf
    /// refuses to build a path from.
    public func readAgentConfig(forProfile name: String) throws -> BotAgentConfig {
        guard BotsService.isAddressableProfile(name) else {
            throw BotsError.profileMissing(name: name)
        }
        let ctx = context(forProfile: name)
        let path = ctx.paths.configYAML
        let exists = ctx.makeTransport().fileExists(path)
        let yaml = exists ? readBounded(ctx, path, limit: Self.maxConfigYAMLBytes) : nil
        return Self.parseAgentConfig(
            yaml: yaml ?? "",
            profileName: name,
            configPath: path,
            configExists: exists,
            // An existing file we could not read yields the same all-nil
            // snapshot as an absent one; `configReadable` is what keeps the UI
            // from calling that "unpinned". See `BotAgentConfig.configReadable`.
            configReadable: !exists || yaml != nil,
            essentialHermesAgentSkill: capabilities.hasEssentialHermesAgentSkill
        )
    }

    /// Pure parse, split out so the fixture suite can pin every shape without
    /// a filesystem.
    static func parseAgentConfig(
        yaml: String,
        profileName: String,
        configPath: String,
        configExists: Bool,
        configReadable: Bool = true,
        essentialHermesAgentSkill: Bool
    ) -> BotAgentConfig {
        let parsed = HermesYAML.parseNestedYAML(yaml)

        func scalar(_ key: String) -> String? {
            guard let raw = parsed.values[key] else { return nil }
            let value = HermesYAML.stripYAMLQuotes(raw)
            return value.isEmpty ? nil : value
        }

        // `skills.disabled` is a bullet list in every file Hermes writes, but
        // hand-edited configs use the flow form too — accept both, exactly as
        // the root-profile reader does.
        var disabled = Set(parsed.lists["skills.disabled"] ?? [])
        if disabled.isEmpty, let inline = parsed.values["skills.disabled"] {
            let trimmed = inline.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                disabled = Set(HermesYAML.parseFlatFlowList(String(trimmed.dropFirst().dropLast())))
            }
        }
        disabled = Set(disabled.filter { !$0.isEmpty })
        // v0.20.6+: Hermes drops `hermes-agent` from every read of the list
        // regardless of the file, so it must never render as OFF.
        if essentialHermesAgentSkill { disabled.remove("hermes-agent") }

        var toolsets: [String: [String]] = [:]
        for (key, items) in parsed.lists where key.hasPrefix("platform_toolsets.") {
            let platform = String(key.dropFirst("platform_toolsets.".count))
            guard !platform.isEmpty, !platform.contains(".") else { continue }
            toolsets[platform] = items
        }

        var serverNames: Set<String> = []
        for key in parsed.values.keys where key.hasPrefix("mcp_servers.") {
            let rest = key.dropFirst("mcp_servers.".count)
            guard let first = rest.split(separator: ".").first else { continue }
            serverNames.insert(String(first))
        }
        for key in parsed.lists.keys where key.hasPrefix("mcp_servers.") {
            let rest = key.dropFirst("mcp_servers.".count)
            guard let first = rest.split(separator: ".").first, rest.contains(".") else { continue }
            serverNames.insert(String(first))
        }
        let servers = serverNames.sorted().map { server -> BotMCPServerState in
            let raw = parsed.values["mcp_servers.\(server).enabled"].map(HermesYAML.stripYAMLQuotes)
            return BotMCPServerState(name: server, explicitlyEnabled: raw.flatMap(Self.parseBool))
        }

        return BotAgentConfig(
            profileName: profileName,
            configPath: configPath,
            configExists: configExists,
            configReadable: configReadable,
            model: BotConfigValue(pinned: scalar("model.default")),
            provider: BotConfigValue(pinned: scalar("model.provider")),
            modelBaseURL: scalar("model.base_url"),
            disabledSkills: disabled,
            platformToolsets: toolsets,
            mcpServers: servers
        )
    }

    /// Hermes reads these flags under YAML 1.1 semantics and additionally
    /// accepts the string forms (`tools_config._parse_enabled_flag`,
    /// `mcp_config.py:734-737`). Anything unrecognized is left `nil` — an
    /// origin of "Hermes default" — rather than guessed at.
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// Reuse the shared preflight on the bot's own pinned values, so a bot
    /// pinned to a model its provider can't serve is caught before the user
    /// opens a conversation with it.
    ///
    /// Cheap because `ModelPreflight.check` is pure — no extra process, no
    /// extra read. Returns `nil` when the bot pins neither key (nothing to
    /// check: the agent will run on Hermes' defaults).
    public func preflight(_ config: BotAgentConfig) -> ModelPreflight.Result? {
        guard config.model.isPinned || config.provider.isPinned else { return nil }
        var hermes = HermesConfig.empty
        hermes.model = config.model.pinned ?? ""
        hermes.provider = config.provider.pinned ?? ""
        // Carried so the loopback branch of `check` behaves the same for a bot
        // as for the root profile: a `custom` provider on a loopback base URL
        // with an empty model is CONFIGURED (Hermes auto-detects the loaded
        // model), not "missing model".
        hermes.modelBaseURL = config.modelBaseURL ?? ""
        return ModelPreflight.check(hermes)
    }

    // MARK: - Writing: model / provider pin

    /// Pin the bot's model and provider.
    ///
    /// Two invocations because Hermes has no combined verb — the same shape as
    /// the root path in `HermesFileService.saveModelConfig`, and the same key
    /// names: `model.provider` and `model.default`. The provider goes first so
    /// a failure between the two leaves the bot on its old model with the new
    /// provider rather than the reverse (a model name with no provider to
    /// serve it).
    ///
    /// Empty values are refused rather than written: `hermes config set k ""`
    /// stores an empty string, which is not the same as unpinning. Use
    /// ``clearModelPin(forProfile:)`` for that.
    @discardableResult
    public func setModelPin(
        forProfile name: String,
        provider: String?,
        model: String?,
        timeout: TimeInterval = 60
    ) throws -> [ProcessResult] {
        var results: [ProcessResult] = []
        if let provider {
            let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BotsError.invalidValue(key: "model.provider") }
            results.append(try setValue(forProfile: name, key: "model.provider", value: trimmed, timeout: timeout))
        }
        if let model {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw BotsError.invalidValue(key: "model.default") }
            results.append(try setValue(forProfile: name, key: "model.default", value: trimmed, timeout: timeout))
        }
        return results
    }

    /// Remove both model keys from the bot's `config.yaml`, returning it to
    /// Hermes' built-in default — **not** to the root profile's model, which
    /// the bot never inherited (see ``BotConfigOrigin``).
    ///
    /// `hermes config unset` exits non-zero with "Config key not set" for a key
    /// that was never pinned (`config.py:6058-6060`), which is a success from
    /// the caller's point of view, so those results are returned rather than
    /// thrown. Callers that need to distinguish should re-read.
    @discardableResult
    public func clearModelPin(forProfile name: String, timeout: TimeInterval = 60) throws -> [ProcessResult] {
        [
            try unsetValue(forProfile: name, key: "model.default", timeout: timeout),
            try unsetValue(forProfile: name, key: "model.provider", timeout: timeout),
        ]
    }

    // MARK: - Writing: toolsets

    /// Enable or disable a toolset for the bot on one platform.
    ///
    /// `hermes -p <bot> tools {enable|disable} <name…> --platform <p>` —
    /// verified against `hermes_cli/subcommands/tools.py:43-74` at the audited
    /// tag, the same argv the root-profile Tools screen shells
    /// (`ToolsViewModel.toggleTool`). Hermes writes the result to
    /// `platform_toolsets.<platform>` (`tools_config._apply_toolset_change` →
    /// `_save_platform_tools` → `save_config`), which is what
    /// ``BotAgentConfig/platformToolsets`` reads back.
    ///
    /// Non-zero exit is returned, not thrown: `tools enable` prints "Unknown
    /// toolset 'x'" and platform-restriction refusals as its own actionable
    /// text, and a Scarf paraphrase would lose it.
    @discardableResult
    public func setToolsetEnabled(
        forProfile name: String,
        toolset: String,
        platform: String = "cli",
        enabled: Bool,
        timeout: TimeInterval = 60
    ) throws -> ProcessResult {
        let toolset = toolset.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolset.isEmpty, !toolset.hasPrefix("-") else {
            throw BotsError.invalidValue(key: "toolset")
        }
        guard !platform.isEmpty, !platform.hasPrefix("-") else {
            throw BotsError.invalidValue(key: "platform")
        }
        return try run(
            forProfile: name,
            args: ["tools", enabled ? "enable" : "disable", toolset, "--platform", platform],
            timeout: timeout
        )
    }

    // MARK: - Writing: MCP enablement

    /// Enable or disable one MCP server for the bot.
    ///
    /// Routed through `config set mcp_servers.<name>.enabled <bool>` because
    /// that is the key Hermes reads (`agent/coding_context.py:711-729`) and it
    /// is a **scalar**, which is the one thing `hermes config set` can write.
    /// The `hermes mcp configure` verb exists but is an interactive checklist
    /// (`hermes_cli/subcommands/mcp.py:83-86`) with no non-interactive form,
    /// so it is not usable from a GUI on either the root or the bot path.
    ///
    /// - Throws: ``BotsError/invalidValue(key:)`` when `server` contains a `.`
    ///   or other character that would change which key is written — a dotted
    ///   server name would silently nest one level deeper.
    @discardableResult
    public func setMCPServerEnabled(
        forProfile name: String,
        server: String,
        enabled: Bool,
        timeout: TimeInterval = 60
    ) throws -> ProcessResult {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeKeySegment(server) else {
            throw BotsError.invalidValue(key: "mcp_servers.\(server).enabled")
        }
        return try setValue(
            forProfile: name,
            key: "mcp_servers.\(server).enabled",
            value: enabled ? "true" : "false",
            timeout: timeout
        )
    }

    // MARK: - Skills enablement (read-only, deliberately)

    /// Whether Scarf can write this bot's skill enablement. **Always `false`
    /// at the audited tag**, and the property exists so callers state the
    /// reason rather than silently omitting a toggle.
    ///
    /// There is no `hermes skills enable`/`disable` verb
    /// (`hermes_cli/subcommands/skills.py` has trust/untrust, browse, search,
    /// install, inspect, list, check, update, audit, uninstall, reset,
    /// list-modified, diff, opt-out, opt-in, repair-official, publish,
    /// snapshot, tap — and nothing else). Enablement lives only in
    /// `skills.disabled`, a **list**, which `hermes config set` cannot express.
    /// The root-profile Skills screen has the same gap and renders the state
    /// read-only; the bot path mirrors it rather than forking a bespoke YAML
    /// list writer that the root path would not share. Charter C5: a verb Scarf
    /// cannot verify is a verb Scarf does not shell.
    public var canWriteSkillEnablement: Bool { false }

    // MARK: - SOUL.md

    /// Read the bot's `SOUL.md` for editing.
    ///
    /// - Returns: `nil` when the file does not exist — normal, and distinct
    ///   from an empty file.
    /// - Throws: ``BotsError/unsafeToRead(path:)`` when the file exists but
    ///   cannot be turned into an editable buffer (unreadable, over
    ///   ``maxSoulBytes``, not UTF-8). This is the **refuse-degraded-merge-base**
    ///   discipline Phase A's profile writer established, applied to a
    ///   whole-file editor: silently handing the UI `""` for a file that is
    ///   really there invites the user to "save" and replace someone's identity
    ///   prompt with an empty document. Display code that wants to degrade must
    ///   catch this explicitly and then refuse to enable its save button.
    public func readSoul(forProfile name: String) throws -> String? {
        guard BotsService.isAddressableProfile(name) else {
            throw BotsError.profileMissing(name: name)
        }
        let ctx = context(forProfile: name)
        let path = ctx.paths.soulMD
        let transport = ctx.makeTransport()
        guard transport.fileExists(path) else { return nil }
        if let stat = transport.stat(path), stat.size > Int64(Self.maxSoulBytes) {
            throw BotsError.unsafeToRead(path: path)
        }
        guard let data = try? transport.readFile(path), data.count <= Self.maxSoulBytes,
              let text = String(data: data, encoding: .utf8)
        else { throw BotsError.unsafeToRead(path: path) }
        return text
    }

    /// Replace the bot's `SOUL.md`.
    ///
    /// This is a whole-file write, matching how Hermes itself treats the file
    /// (it is read wholesale as system-prompt slot #1 and has no structure
    /// Scarf must preserve). The guard that matters is the same one
    /// ``BotsService/saveIdentity(_:)`` carries: an existing file that cannot
    /// be read is re-checked here, immediately before the write, and refused —
    /// so a save can never be built on a degraded view of what is on disk.
    ///
    /// **On v0.21's protected-instruction-files gate.** Hermes gates *agent*
    /// writes to `SOUL.md`/`AGENTS.md`/`CLAUDE.md` behind an always-ask
    /// approval prompt (`tools/file_tools.py:715-950`,
    /// `_check_protected_instruction_write`). That gate exists because an
    /// injected instruction could make the agent rewrite its own identity. It
    /// does **not** apply here and must not be simulated: this write is the
    /// human editing their own bot in a GUI they opened, which is precisely the
    /// approval the gate is asking for. The gate lives in the agent's file
    /// tools, not in the filesystem, so a transport write never reaches it.
    public func writeSoul(forProfile name: String, content: String, timeout: TimeInterval = 60) throws {
        guard capabilities.hasBotMode else { throw BotsError.unsupported }
        guard BotsService.isAddressableProfile(name) else {
            throw BotsError.profileMissing(name: name)
        }
        let ctx = context(forProfile: name)
        let dir = ctx.paths.home
        let transport = ctx.makeTransport()
        guard transport.fileExists(dir) else { throw BotsError.profileMissing(name: name) }

        let path = ctx.paths.soulMD
        // Re-verify readability of what we are about to replace. `readSoul`
        // returning nil (absent) is fine; it throwing is not.
        _ = try readSoul(forProfile: name)

        guard let data = content.data(using: .utf8), data.count <= Self.maxSoulBytes else {
            throw BotsError.unsafeToWrite(path: path)
        }
        try transport.writeFile(path, data: data)
    }

    // MARK: - CLI plumbing

    /// One component of a dotted config key that Scarf will interpolate and
    /// then read back by the same path.
    ///
    /// Deliberately a **refusal**, not `ConfigDottedKeySegment.escaped(_:)`:
    /// that helper exists for names the user invented and Scarf only ever
    /// writes (quick commands), where a lossy rewrite is acceptable. An MCP
    /// server name is a key Scarf must also *read back* out of the same file
    /// to render its toggle, and an escaped or dot-stripped name no longer
    /// matches the server it came from — the toggle would flip a key belonging
    /// to nothing. A name Hermes itself would not produce is an error, not
    /// something to sanitize.
    static func isSafeKeySegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, !segment.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return segment.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A whole dotted key: every segment safe, no empty segment. Mirrors
    /// `hermes_cli/config.py:5751-5757`, which rejects leading/trailing/doubled
    /// dots outright.
    static func isSafeDottedKey(_ key: String) -> Bool {
        guard key == key.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return false }
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 1 else { return false }
        return segments.allSatisfy { isSafeKeySegment(String($0)) }
    }

    /// `hermes -p <bot> config set <key> <value>`.
    ///
    /// Note that Hermes routes credential-shaped keys away from `config.yaml`
    /// entirely: `_is_env_config_key` sends them to the profile's `.env` via
    /// `save_provider_env_credential` (`config.py:5774-5781`). Still the bot's
    /// own file — profiles get their own `.env` at creation — but a key written
    /// that way will not read back through ``readAgentConfig(forProfile:)`,
    /// which parses `config.yaml` only. Nothing this service writes today is
    /// env-shaped; a future caller passing an arbitrary key should know.
    @discardableResult
    public func setValue(
        forProfile name: String,
        key: String,
        value: String,
        timeout: TimeInterval = 60
    ) throws -> ProcessResult {
        guard Self.isSafeDottedKey(key) else {
            throw BotsError.invalidValue(key: key)
        }
        return try run(forProfile: name, args: ["config", "set", key, value], timeout: timeout)
    }

    /// `hermes -p <bot> config unset <key>`.
    @discardableResult
    public func unsetValue(
        forProfile name: String,
        key: String,
        timeout: TimeInterval = 60
    ) throws -> ProcessResult {
        guard Self.isSafeDottedKey(key) else {
            throw BotsError.invalidValue(key: key)
        }
        return try run(forProfile: name, args: ["config", "unset", key], timeout: timeout)
    }

    /// Compose the full argv for a bot-scoped invocation. Exposed for tests,
    /// which assert on it directly — an argv that silently loses its `-p` is
    /// the Phase B hazard, and it is worth pinning without a subprocess.
    public func argv(forProfile name: String, args: [String]) -> [String] {
        Self.profileFlag(name) + args
    }

    /// Spawn `hermes -p <bot> <args…>`.
    ///
    /// The transport comes from the **pinned** context so the SSH path also
    /// carries a matching `HERMES_HOME=` assignment; the `-p` flag is what
    /// makes the local path correct. Belt and braces on purpose: they agree
    /// (`resolve_profile_env` derives the root from a profile-shaped
    /// `HERMES_HOME` by taking its grandparent, `profiles.py:2505-2512`), and
    /// either one alone leaves a host shape unprotected.
    @discardableResult
    public func run(
        forProfile name: String,
        args: [String],
        timeout: TimeInterval = 60
    ) throws -> ProcessResult {
        guard capabilities.hasBotMode else { throw BotsError.unsupported }
        guard BotsService.isAddressableProfile(name) else {
            throw BotsError.profileMissing(name: name)
        }
        let ctx = context(forProfile: name)
        return try ctx.makeTransport().runProcess(
            executable: ctx.paths.hermesBinary,
            args: argv(forProfile: name, args: args),
            stdin: nil,
            timeout: timeout
        )
    }

    private func readBounded(_ ctx: ServerContext, _ path: String, limit: Int) -> String? {
        let transport = ctx.makeTransport()
        if let stat = transport.stat(path), stat.size > Int64(limit) { return nil }
        guard let data = try? transport.readFile(path), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
