import Testing
import Foundation
@testable import ScarfCore

/// P0 of the Bot Mode **Phase B** cycle — the ScarfCore foundation for
/// configuring a bot's AGENT (model/provider pin, skills/toolsets/MCP
/// enablement, `SOUL.md`) against the BOT'S OWN profile home.
///
/// Pinned against real Hermes source at the audited tag v2026.8.31
/// (Hermes 0.21.0):
/// - `hermes_cli/main.py:521-724` — `_apply_profile_override`: `-p` is consumed
///   from raw argv BEFORE argparse, sets `HERMES_HOME`, and is stripped.
/// - `hermes_cli/profiles.py:2489-2523` — `resolve_profile_env`: `default`
///   resolves to the ROOT home; a missing named profile raises.
/// - `hermes_cli/config.py:3936-4080` — `_load_config_impl`: the effective
///   config is `DEFAULT_CONFIG` + `<HERMES_HOME>/config.yaml` + managed scope.
///   **No root-profile layer.**
/// - `hermes_cli/profiles.py:773-805, 1177-1310` — `_seed_model_config` /
///   `create_profile`: the root's `model:` block is COPIED once at creation.
/// - `hermes_cli/subcommands/tools.py:32-74` — `tools list/enable/disable
///   --platform`.
/// - `hermes_cli/tools_config.py:2655-2656` — `platform_toolsets.<platform>`.
/// - `agent/coding_context.py:711-729`, `hermes_cli/mcp_config.py:734-737` —
///   `mcp_servers.<name>.enabled`, defaulting to true when absent.
/// - `agent/prompt_builder.py:2196-2229`, `tools/bot_mode_probe.py:359` —
///   `SOUL.md` lives at `<profile_dir>/SOUL.md`.
///
/// The filesystem-facing suite drives a real `LocalTransport` against a
/// temporary profile tree, the same way Phase A's B0 did, so the paths
/// exercised are the ones the SSH transport implements too.
@Suite struct BotModePhaseBP0Tests {

    // MARK: - Fixtures

    static let capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")

    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-bp0-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A root home with a distinct model pin, plus named profiles carrying
    /// whatever files each test needs. The ROOT's values are deliberately
    /// unlike every bot's: if a read ever bleeds, the assertion names it.
    @discardableResult
    private func makeTree(
        at root: URL,
        rootConfig: String? = """
        model:
          default: root-model
          provider: root-provider
        skills:
          disabled:
            - root-only-skill
        """,
        profiles: [String: (config: String?, soul: String?)] = [:]
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let rootConfig {
            try rootConfig.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        }
        for (name, files) in profiles {
            let dir = root.appendingPathComponent("profiles/\(name)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let config = files.config {
                try config.write(to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            }
            if let soul = files.soul {
                try soul.write(to: dir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    private func service(root: URL) -> BotAgentConfigService {
        BotAgentConfigService(context: .local(home: root), capabilities: Self.capabilities)
    }

    // MARK: - argv: `-p` is never optional

    /// The Phase B hazard in one assertion: every invocation carries `-p <bot>`.
    @Test func everyInvocationCarriesTheProfileFlag() {
        let svc = service(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(svc.argv(forProfile: "scout", args: ["config", "set", "model.default", "m"])
                == ["-p", "scout", "config", "set", "model.default", "m"])
        #expect(svc.argv(forProfile: "scout", args: ["tools", "enable", "web", "--platform", "cli"])
                == ["-p", "scout", "tools", "enable", "web", "--platform", "cli"])
    }

    /// `default` gets an explicit `-p default` rather than a bare invocation.
    ///
    /// Omitting it would let step 2 of `_apply_profile_override` follow the
    /// host's sticky `~/.hermes/active_profile`, so on a machine whose active
    /// profile is `work` the *default bot's* `config set` would land in
    /// `work/config.yaml`. `resolve_profile_env("default")` returns the root
    /// (`profiles.py:2513-2514`), so the flag is exact, not just defensive.
    @Test func theDefaultBotIsAddressedExplicitlyNotByOmission() {
        let svc = service(root: URL(fileURLWithPath: "/tmp/x"))
        for name in ["default", "", "  ", "UPPER", "../escape"] {
            #expect(svc.argv(forProfile: name, args: ["config", "get", "model.default"])
                    == ["-p", "default", "config", "get", "model.default"],
                    "\(name) must address the root profile explicitly")
        }
    }

    /// The SSH transport's `HERMES_HOME=` assignment is emitted only for a
    /// profile-scoped home — for the root it emits nothing (M0b pins this).
    /// So on SSH, the default bot has NO env scope either, and `-p default` is
    /// again the only thing between it and the host's active profile.
    @Test func sshCarriesTheEnvScopeForABotAndNothingForTheRoot() {
        let base = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes"))
        )
        let svc = BotAgentConfigService(context: base, capabilities: Self.capabilities)

        func command(_ profile: String) -> String {
            let ctx = svc.context(forProfile: profile)
            guard case .ssh(let config) = ctx.kind else { return "" }
            let transport = SSHTransport(contextID: ctx.id, config: config, displayName: "box")
            return transport.composedRemoteCommand(
                executable: "hermes",
                args: svc.argv(forProfile: profile, args: ["config", "set", "model.default", "m"])
            )
        }

        #expect(command("scout").hasPrefix("HERMES_HOME=\"$HOME/.hermes/profiles/scout\" "))
        #expect(command("scout").contains("\"-p\" \"scout\""))
        // Root home ⇒ no assignment; the flag is the whole scope.
        #expect(!command("default").contains("HERMES_HOME="))
        #expect(command("default").contains("\"-p\" \"default\""))
    }

    /// A profile-scoped window (#126) must not leak into the bot's argv or its
    /// home: `pinnedToProfile` root-normalizes first, so `-p` and the env
    /// assignment agree with each other and with the file paths.
    @Test func aWindowScopedToAnotherProfileStillResolvesTheBotsOwnHome() {
        let scoped = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes/profiles/work"))
        )
        let svc = BotAgentConfigService(context: scoped, capabilities: Self.capabilities)
        #expect(svc.configPath(forProfile: "scout") == "~/.hermes/profiles/scout/config.yaml")
        #expect(svc.soulPath(forProfile: "scout") == "~/.hermes/profiles/scout/SOUL.md")
        // And the default bot lands on the ROOT, never on `work`.
        #expect(svc.configPath(forProfile: "default") == "~/.hermes/config.yaml")
        #expect(svc.soulPath(forProfile: "default") == "~/.hermes/SOUL.md")
    }

    // MARK: - Reads land in profiles/<bot>/, never the root

    @Test func aBotsConfigIsReadFromItsOwnProfileDirectory() throws {
        let root = tempRoot("read")
        try makeTree(at: root, profiles: [
            "scout": ("""
            model:
              default: scout-model
              provider: scout-provider
            """, nil),
        ])
        let svc = service(root: root)
        let scout = try svc.readAgentConfig(forProfile: "scout")
        #expect(scout.configPath == root.path + "/profiles/scout/config.yaml")
        #expect(scout.configExists)
        #expect(scout.model.pinned == "scout-model")
        #expect(scout.provider.pinned == "scout-provider")

        // …and the default bot reads the root, which is ITS home.
        let def = try svc.readAgentConfig(forProfile: "default")
        #expect(def.configPath == root.path + "/config.yaml")
        #expect(def.model.pinned == "root-model")
    }

    /// **The layering verdict, as an executable assertion.** A bot with no
    /// `config.yaml` of its own does NOT inherit the root's model — Hermes
    /// resolves it from `DEFAULT_CONFIG`. Rendering `root-model` as the bot's
    /// inherited default would be a lie, so the read must report "unpinned".
    @Test func aBotWithNoConfigInheritsNothingFromTheRoot() throws {
        let root = tempRoot("layering")
        try makeTree(at: root, profiles: ["fresh": (nil, nil)])
        let svc = service(root: root)
        let fresh = try svc.readAgentConfig(forProfile: "fresh")
        #expect(!fresh.configExists)
        #expect(fresh.model.pinned == nil)
        #expect(fresh.provider.pinned == nil)
        #expect(fresh.model.origin == .hermesDefault)
        #expect(fresh.disabledSkills.isEmpty, "the root's skills.disabled must not bleed in")
        #expect(fresh.platformToolsets.isEmpty)
        #expect(fresh.mcpServers.isEmpty)
    }

    /// **Audit fix.** A `config.yaml` that exists but cannot be read produces
    /// the same all-nil snapshot as an absent one, so without `configReadable`
    /// the UI would confidently report "running on Hermes' defaults" for a bot
    /// that may be pinned to anything. The absent case must stay trustworthy.
    @Test func anUnreadableConfigIsNotReportedAsUnpinned() throws {
        let root = tempRoot("unreadable")
        try makeTree(at: root, profiles: ["huge": (nil, nil), "fresh": (nil, nil)])
        let path = root.appendingPathComponent("profiles/huge/config.yaml")
        try String(repeating: "#", count: BotAgentConfigService.maxConfigYAMLBytes + 1)
            .write(to: path, atomically: true, encoding: .utf8)

        let svc = service(root: root)
        let huge = try svc.readAgentConfig(forProfile: "huge")
        #expect(huge.configExists)
        #expect(!huge.configReadable)
        #expect(!huge.isTrustworthy)
        #expect(huge.model.pinned == nil, "nil because we could not look, not because it's unset")

        // An absent file is a real answer and stays trustworthy.
        let fresh = try svc.readAgentConfig(forProfile: "fresh")
        #expect(!fresh.configExists)
        #expect(fresh.isTrustworthy)
    }

    /// A bot that pins only ONE of the two model keys reports exactly that —
    /// per-key origins, not a whole-section verdict. (`_seed_model_config`
    /// copies both at creation, but a user who unsets one lands here.)
    @Test func originIsPerKeyNotPerSection() throws {
        let root = tempRoot("perkey")
        try makeTree(at: root, profiles: [
            "half": ("model:\n  provider: anthropic\n", nil),
        ])
        let half = try service(root: root).readAgentConfig(forProfile: "half")
        #expect(half.provider.origin == .pinned)
        #expect(half.provider.pinned == "anthropic")
        #expect(half.model.origin == .hermesDefault)
        #expect(half.model.pinned == nil)
    }

    // MARK: - Skills / toolsets / MCP reads

    @Test func readsDisabledSkillsToolsetsAndMCPFromTheBotsFile() throws {
        let root = tempRoot("surface")
        try makeTree(at: root, profiles: [
            "scout": ("""
            skills:
              disabled:
                - noisy-skill
                - another
            platform_toolsets:
              cli:
                - web
                - files
              discord:
                - web
            mcp_servers:
              figma:
                command: figma-mcp
                enabled: false
              browser:
                command: browser-mcp
              tophat:
                command: tophat-mcp
                enabled: true
            """, nil),
        ])
        let scout = try service(root: root).readAgentConfig(forProfile: "scout")
        #expect(scout.disabledSkills == ["noisy-skill", "another"])
        #expect(scout.toolsets(forPlatform: "cli") == ["web", "files"])
        #expect(scout.toolsets(forPlatform: "discord") == ["web"])
        #expect(scout.toolsets(forPlatform: "telegram") == nil,
                "an unpinned platform must be nil, not an empty list Scarf invented")

        #expect(scout.mcpServers.map(\.name) == ["browser", "figma", "tophat"])
        let byName = Dictionary(uniqueKeysWithValues: scout.mcpServers.map { ($0.name, $0) })
        #expect(byName["figma"]?.isEnabled == false)
        #expect(byName["figma"]?.origin == .pinned)
        // Absent `enabled:` ⇒ enabled by Hermes' default, not by user choice.
        #expect(byName["browser"]?.explicitlyEnabled == nil)
        #expect(byName["browser"]?.isEnabled == true)
        #expect(byName["browser"]?.origin == .hermesDefault)
        #expect(byName["tophat"]?.origin == .pinned)
    }

    /// Hermes drops `hermes-agent` from every read of `skills.disabled` on
    /// v0.20.6+, so a stale file listing it must not render the skill as OFF.
    @Test func theEssentialHermesAgentSkillIsNeverShownDisabled() throws {
        let yaml = "skills:\n  disabled:\n    - hermes-agent\n    - noisy\n"
        let onFloor = BotAgentConfigService.parseAgentConfig(
            yaml: yaml, profileName: "scout", configPath: "/x", configExists: true,
            essentialHermesAgentSkill: true)
        #expect(onFloor.disabledSkills == ["noisy"])

        let below = BotAgentConfigService.parseAgentConfig(
            yaml: yaml, profileName: "scout", configPath: "/x", configExists: true,
            essentialHermesAgentSkill: false)
        #expect(below.disabledSkills == ["hermes-agent", "noisy"])
    }

    /// Hand-edited configs use the flow form; Hermes' own writer uses bullets.
    @Test func bothSkillsDisabledSpellingsParse() {
        let flow = BotAgentConfigService.parseAgentConfig(
            yaml: "skills:\n  disabled: [alpha, 'beta']\n",
            profileName: "s", configPath: "/x", configExists: true,
            essentialHermesAgentSkill: true)
        #expect(flow.disabledSkills == ["alpha", "beta"])
    }

    /// `_parse_enabled_flag` accepts YAML 1.1 bool synonyms and their string
    /// forms; anything else is "no explicit choice", never a guess.
    @Test func mcpEnabledFlagFollowsHermesTruthiness() {
        #expect(BotAgentConfigService.parseBool("true") == true)
        #expect(BotAgentConfigService.parseBool("YES") == true)
        #expect(BotAgentConfigService.parseBool("on") == true)
        #expect(BotAgentConfigService.parseBool("1") == true)
        #expect(BotAgentConfigService.parseBool("false") == false)
        #expect(BotAgentConfigService.parseBool("off") == false)
        #expect(BotAgentConfigService.parseBool("no") == false)
        #expect(BotAgentConfigService.parseBool("0") == false)
        #expect(BotAgentConfigService.parseBool("maybe") == nil)
    }

    // MARK: - Preflight reuse

    @Test func preflightRunsOnTheBotsOwnPinNotTheRoots() throws {
        let root = tempRoot("preflight")
        try makeTree(at: root, profiles: [
            "half": ("model:\n  provider: anthropic\n", nil),
            "whole": ("model:\n  default: m\n  provider: anthropic\n", nil),
            "bare": (nil, nil),
        ])
        let svc = service(root: root)
        #expect(svc.preflight(try svc.readAgentConfig(forProfile: "half")) == .missingModel)
        #expect(svc.preflight(try svc.readAgentConfig(forProfile: "whole")) == .configured)
        // Nothing pinned ⇒ nothing to check; the agent runs on Hermes' defaults.
        #expect(svc.preflight(try svc.readAgentConfig(forProfile: "bare")) == nil)
    }

    // MARK: - Write argv composition

    @Test func modelPinWritesTheSameKeysTheRootPathWrites() throws {
        // Provider first, so a mid-failure never leaves a model with no
        // provider to serve it — mirroring `HermesFileService.saveModelConfig`.
        let svc = service(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(svc.argv(forProfile: "scout", args: ["config", "set", "model.provider", "anthropic"])
                == ["-p", "scout", "config", "set", "model.provider", "anthropic"])
        #expect(svc.argv(forProfile: "scout", args: ["config", "unset", "model.default"])
                == ["-p", "scout", "config", "unset", "model.default"])
    }

    @Test func refusesValuesAndKeysThatWouldWriteSomethingElse() {
        let svc = service(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(throws: BotsError.invalidValue(key: "model.provider")) {
            try svc.setModelPin(forProfile: "scout", provider: "   ", model: nil)
        }
        #expect(throws: BotsError.invalidValue(key: "toolset")) {
            try svc.setToolsetEnabled(forProfile: "scout", toolset: "--platform", enabled: true)
        }
        // A dotted MCP server name would nest one level deeper than the key
        // the reader maps back — refuse, don't sanitize.
        #expect(throws: BotsError.invalidValue(key: "mcp_servers.a.b.enabled")) {
            try svc.setMCPServerEnabled(forProfile: "scout", server: "a.b", enabled: false)
        }
    }

    @Test func dottedKeyValidationMirrorsHermesOwnRejections() {
        #expect(BotAgentConfigService.isSafeDottedKey("model.default"))
        #expect(BotAgentConfigService.isSafeDottedKey("mcp_servers.figma.enabled"))
        #expect(!BotAgentConfigService.isSafeDottedKey("agent."))
        #expect(!BotAgentConfigService.isSafeDottedKey(".agent"))
        #expect(!BotAgentConfigService.isSafeDottedKey("a..b"))
        #expect(!BotAgentConfigService.isSafeDottedKey(" model.default"))
        #expect(!BotAgentConfigService.isSafeDottedKey("--force"))
    }

    /// Skills enablement has no writable path at the audited tag, and the
    /// service says so rather than offering a toggle that does nothing.
    @Test func skillEnablementIsHonestlyReadOnly() {
        #expect(service(root: URL(fileURLWithPath: "/tmp/x")).canWriteSkillEnablement == false)
    }

    // MARK: - SOUL.md

    @Test func soulRoundTripsInTheBotsOwnProfileDirectory() throws {
        let root = tempRoot("soul")
        try makeTree(at: root, profiles: ["scout": (nil, "# Scout\nTerse.\n")])
        // A root SOUL.md that must never be read or written by a bot path.
        try "# ROOT SOUL\n".write(to: root.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let svc = service(root: root)
        #expect(try svc.readSoul(forProfile: "scout") == "# Scout\nTerse.\n")

        try svc.writeSoul(forProfile: "scout", content: "# Scout\nRewritten.\n")
        #expect(try svc.readSoul(forProfile: "scout") == "# Scout\nRewritten.\n")
        // The root file is untouched — the #1 Phase B hazard, asserted.
        let rootSoul = try String(contentsOf: root.appendingPathComponent("SOUL.md"), encoding: .utf8)
        #expect(rootSoul == "# ROOT SOUL\n")
    }

    /// Absent is normal and distinct from empty: a profile that has never had
    /// an identity prompt reads `nil`, and writing creates the file in the
    /// bot's directory.
    @Test func anAbsentSoulReadsNilAndWritingCreatesIt() throws {
        let root = tempRoot("soul-absent")
        try makeTree(at: root, profiles: ["fresh": (nil, nil)])
        let svc = service(root: root)
        #expect(try svc.readSoul(forProfile: "fresh") == nil)
        try svc.writeSoul(forProfile: "fresh", content: "# Fresh\n")
        #expect(try svc.readSoul(forProfile: "fresh") == "# Fresh\n")
        #expect(FileManager.default.fileExists(
            atPath: root.path + "/profiles/fresh/SOUL.md"))
    }

    /// Refuse-degraded-merge-base, applied to a whole-file editor: a file that
    /// exists but cannot be turned into a buffer must THROW, never read as
    /// `""` — otherwise the user "saves" an empty editor over a real identity
    /// prompt. `writeSoul` re-checks immediately before writing, so the guard
    /// holds even if the caller ignored the read error.
    @Test func anUnreadableSoulRefusesBothReadAndWrite() throws {
        let root = tempRoot("soul-degraded")
        try makeTree(at: root, profiles: ["scout": (nil, nil)])
        let path = root.appendingPathComponent("profiles/scout/SOUL.md")
        // Over the cap: never pulled across the transport, never editable.
        let oversized = String(repeating: "x", count: BotAgentConfigService.maxSoulBytes + 1)
        try oversized.write(to: path, atomically: true, encoding: .utf8)

        let svc = service(root: root)
        #expect(throws: BotsError.unsafeToRead(path: path.path)) {
            try svc.readSoul(forProfile: "scout")
        }
        #expect(throws: BotsError.unsafeToRead(path: path.path)) {
            try svc.writeSoul(forProfile: "scout", content: "tiny")
        }
        // The oversized file survives the refused write.
        let stillThere = try Data(contentsOf: path)
        #expect(stillThere.count == BotAgentConfigService.maxSoulBytes + 1)
    }

    @Test func anOversizedSoulBodyIsRefusedRatherThanTruncated() throws {
        let root = tempRoot("soul-big-write")
        try makeTree(at: root, profiles: ["scout": (nil, nil)])
        let svc = service(root: root)
        #expect(throws: BotsError.unsafeToWrite(path: root.path + "/profiles/scout/SOUL.md")) {
            try svc.writeSoul(
                forProfile: "scout",
                content: String(repeating: "x", count: BotAgentConfigService.maxSoulBytes + 1))
        }
    }

    /// A profile id Scarf will not build a path from is rejected before it can
    /// reach a filesystem call — the same guard `BotsService` applies.
    @Test func unaddressableProfileIdsAreRefusedEverywhere() {
        let svc = service(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(throws: BotsError.profileMissing(name: "../escape")) {
            try svc.readAgentConfig(forProfile: "../escape")
        }
        #expect(throws: BotsError.profileMissing(name: "../escape")) {
            try svc.readSoul(forProfile: "../escape")
        }
        #expect(throws: BotsError.profileMissing(name: "../escape")) {
            try svc.writeSoul(forProfile: "../escape", content: "x")
        }
    }

    /// A profile directory that does not exist is a refusal, not a directory
    /// Scarf creates — `hermes profile create` owns that, and a SOUL.md in a
    /// bare directory would be a profile Hermes does not know about.
    @Test func writingSoulToAMissingProfileRefuses() throws {
        let root = tempRoot("soul-missing")
        try makeTree(at: root)
        #expect(throws: BotsError.profileMissing(name: "ghost")) {
            try service(root: root).writeSoul(forProfile: "ghost", content: "x")
        }
    }

    /// Below the Bot Mode floor, writes refuse rather than landing keys that
    /// version of Hermes ignores (charter C1).
    @Test func writesRefuseBelowTheBotModeFloor() throws {
        let root = tempRoot("floor")
        try makeTree(at: root, profiles: ["scout": (nil, nil)])
        let old = BotAgentConfigService(
            context: .local(home: root),
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.7.1)"))
        #expect(throws: BotsError.unsupported) {
            try old.writeSoul(forProfile: "scout", content: "x")
        }
        #expect(throws: BotsError.unsupported) {
            try old.setModelPin(forProfile: "scout", provider: "anthropic", model: nil)
        }
        // Reads still work — degrading a read would empty the UI for no reason.
        #expect(try old.readAgentConfig(forProfile: "scout").configExists == false)
    }
}

/// Phase B P1 — the shared `hermes tools list` parse.
///
/// The per-bot Agent surface reads a bot's toolsets with the SAME parser the
/// root Tools screen uses (`HermesToolsList`, lifted out of `ToolsViewModel`),
/// because the bot's `config.yaml` only pins `platform_toolsets.<platform>`
/// when something was changed — the effective set is computed by Hermes at
/// read time, so the file alone can never enumerate it.
@Suite("Hermes tools list parser (P1)")
struct HermesToolsListTests {

    @Test("✓/✗ rows carry name, description and enablement")
    func parsesRows() {
        let output = """
        Toolsets for platform cli:
        ✓ enabled  web  🌐 search and fetch pages
        ✗ disabled  shell  🖥 run shell commands

        2 toolsets
        """
        let tools = HermesToolsList.parse(output)
        #expect(tools.map(\.name) == ["web", "shell"])
        #expect(tools[0].enabled)
        #expect(!tools[1].enabled)
        #expect(tools[0].description == "search and fetch pages")
        #expect(tools[0].icon == "🌐")
    }

    @Test("lines that aren't toolset rows are skipped, never guessed at")
    func skipsNonRows() {
        #expect(HermesToolsList.parse("no toolsets configured\n\n").isEmpty)
    }

    @Test("a row with no description falls back to its own name")
    func bareRow() {
        let tools = HermesToolsList.parse("✓ enabled  memory")
        #expect(tools.count == 1)
        #expect(tools[0].name == "memory")
        #expect(tools[0].icon == "🔧")
    }
}
