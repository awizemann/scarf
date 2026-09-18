import Foundation
import Observation
#if canImport(os)
import os
#endif

/// What this Hermes installation can do, derived from `hermes --version`.
///
/// Scarf tracks Hermes feature releases by date-version + semver. UI that
/// branches on a release-gated surface calls the boolean accessors here, so
/// older Hermes installs degrade silently instead of throwing on an unknown
/// CLI subcommand or writing a config key the host ignores (charter C1).
///
/// **There is no per-release narrative here.** It stopped at v0.16 and went
/// stale, and a prose summary of "what v0.14 added" is exactly the kind of
/// release-note claim charter C2 forbids trusting. The authority is the
/// `// MARK: vX.Y (<tag>) flags` sections below: each flag carries the tagged
/// Hermes `file:line` its floor was verified against, and each cluster has a
/// matching parse / all-on / prior-host-degradation / patch-still-on group in
/// `HermesCapabilitiesTests`. Read the MARK sections, not a changelog.
///
/// Two shapes recur and are easy to get wrong:
/// - a **floor** (the surface exists from tag T onward) is `atLeastSemver`;
/// - a **removal window** (present until T, gone after) is an explicit
///   `semver` comparison with inverse semantics — see `hasWebExtractAux` and
///   `hasTavilyWebBackend`.
///
/// A floor is found by walking the symbol across EVERY tag over both the old
/// and new file locations (the v0.21.1 modularization moved argparse blocks
/// from `hermes_cli/main.py` into `hermes_cli/subcommands/<verb>.py`), never
/// by diffing two endpoints — that mistake floored seven surfaces a release
/// too high, see `isV0191OrLater`.
///
/// Pure value type — no side effects. The async detection lives in
/// `HermesCapabilitiesStore`.
public struct HermesCapabilities: Sendable, Equatable {
    /// Raw version line as printed by `hermes --version`. Preserved verbatim
    /// so diagnostics views can show the exact string Scarf saw.
    public let versionLine: String
    /// Parsed `0.X.Y`. `nil` when the output didn't match the expected format
    /// (e.g. Hermes returned an error, or a future format change).
    public let semver: SemVer?
    /// Parsed `YYYY.M.D` from the parenthesized date suffix. `nil` when
    /// absent — older Hermes builds didn't always emit it.
    public let dateVersion: DateVersion?

    public init(versionLine: String, semver: SemVer?, dateVersion: DateVersion?) {
        self.versionLine = versionLine
        self.semver = semver
        self.dateVersion = dateVersion
    }

    /// Sentinel for "not yet detected" / "detection failed". All capability
    /// flags resolve to `false` so unguarded UI stays hidden until the real
    /// version lands.
    public static let empty = HermesCapabilities(
        versionLine: "",
        semver: nil,
        dateVersion: nil
    )

    public var detected: Bool { semver != nil }

    // MARK: - Capability flags
    //
    // Add a new flag here when Scarf gains UI that conditionally branches on
    // a Hermes capability. Keep the comparison conservative: a flag introduced
    // in v0.13.0 should gate on `>= 0.13.0`, not `>= 0.13.5`, so users on
    // an early 0.13 patch still see the surface.

    // MARK: v0.12 (v2026.4.30) flags

    /// `hermes curator` autonomous skill maintenance (v0.12+).
    public var hasCurator: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes fallback` provider management (v0.12+).
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasFallbackCommand: Bool { atLeastSemver(0, 12, 0) }

    // `hasKanban` used to live here on an `atLeastSemver(0, 12, 0)` floor.
    // The P55 re-walk moved it into the v0.13 group below: `kanban` appears
    // ZERO times in `hermes_cli/commands.py` and `hermes_cli/main.py` at
    // `v2026.4.30` (0.12.0), and `hermes_cli/kanban.py` does not exist there.

    /// `hermes -z <prompt>` non-interactive one-shot mode (v0.12+).
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasOneShot: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes skills install <https-url>` direct-URL install (v0.12+).
    public var hasSkillURLInstall: Bool { atLeastSemver(0, 12, 0) }

    /// ACP `session/prompt` accepts image content blocks (v0.12+).
    public var hasACPImagePrompts: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes update --check` preflight (v0.12+).
    public var hasUpdateCheck: Bool { atLeastSemver(0, 12, 0) }

    /// Pluggable TTS providers including native Piper (v0.12+).
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasPiperTTS: Bool { atLeastSemver(0, 12, 0) }

    /// `terminal.backend = vercel` Vercel Sandbox option (v0.12+).
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasVercelTerminal: Bool { atLeastSemver(0, 12, 0) }

    /// `auxiliary.flush_memories` config row was removed in v0.12.
    /// Inverse semantics — `true` means the row should still be shown.
    public var hasFlushMemoriesAux: Bool {
        guard let s = semver else { return false }       // unknown → hide
        return s < SemVer(major: 0, minor: 12, patch: 0) // pre-v0.12 only
    }

    /// `auxiliary.curator` aux task is configurable (v0.12+).
    public var hasCuratorAux: Bool { atLeastSemver(0, 12, 0) }

    /// Microsoft Teams (19th platform) and Yuanbao (18th) added in v0.12.
    ///
    /// The floor lives in ``teamsPlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasTeamsPlatform: Bool { atLeast(Self.teamsPlatformFloor) }

    /// First Hermes version carrying the `teams` adapter — `plugins/platforms/teams/` first exists at
    /// tag v2026.4.30 (0.12.0).
    /// Shared by the flag above and `KnownPlatforms.all`'s `teams` row.
    public static let teamsPlatformFloor = SemVer(major: 0, minor: 12, patch: 0)

    /// First Hermes version carrying the `irc` adapter —
    /// `plugins/platforms/irc/` first exists at tag v2026.4.30 (0.12.0) and is
    /// absent at v2026.4.23 (0.11.0). Consumed only by `KnownPlatforms.all`'s
    /// `irc` row; it lives here, not as an inline literal on that row, so the
    /// roster's gate has the same provenance as every sibling's.
    public static let ircPlatformFloor = SemVer(major: 0, minor: 12, patch: 0)

    /// First Hermes version carrying the `weixin` adapter —
    /// `gateway/platforms/weixin.py` first exists at tag v2026.4.13 (0.9.0) and
    /// is absent at v2026.4.8 (0.8.0). Consumed only by `KnownPlatforms.all`.
    public static let weixinPlatformFloor = SemVer(major: 0, minor: 9, patch: 0)

    /// First Hermes version carrying the `qqbot` adapter —
    /// `gateway/platforms/qqbot.py` first exists at tag v2026.4.16 (0.10.0) and
    /// is absent at v2026.4.13 (0.9.0). Consumed only by `KnownPlatforms.all`.
    public static let qqbotPlatformFloor = SemVer(major: 0, minor: 10, patch: 0)

    /// First Hermes version carrying the `msgraph_webhook` adapter —
    /// `gateway/platforms/msgraph_webhook.py` first exists at tag v2026.5.16
    /// (0.14.0) and is absent at v2026.5.7 (0.13.0). Consumed only by
    /// `KnownPlatforms.all`.
    public static let msgraphWebhookPlatformFloor = SemVer(major: 0, minor: 14, patch: 0)

    /// The floor lives in ``yuanbaoPlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasYuanbaoPlatform: Bool { atLeast(Self.yuanbaoPlatformFloor) }

    /// First Hermes version carrying the `yuanbao` adapter — `gateway/platforms/yuanbao.py` first
    /// exists at tag v2026.4.30 (0.12.0).
    /// Shared by the flag above and `KnownPlatforms.all`'s `yuanbao` row.
    public static let yuanbaoPlatformFloor = SemVer(major: 0, minor: 12, patch: 0)

    /// Cron jobs accept `--workdir` and `--context-from` flags (v0.12+).
    public var hasCronWorkdir: Bool { atLeastSemver(0, 12, 0) }

    /// `prompt_caching.cache_ttl` config knob (v0.12+).
    public var hasPromptCacheTTL: Bool { atLeastSemver(0, 12, 0) }

    /// `redaction.enabled` is now off by default in v0.12 — Scarf surfaces
    /// the toggle so users can flip it back on. v0.13 flips the server-side
    /// default back to ON; the toggle remains so users on v0.13 can opt out.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasRedactionToggle: Bool { atLeastSemver(0, 12, 0) }

    // MARK: v0.13 (v2026.5.7) flags

    /// `/goal` slash command + Persistent Goals + Checkpoints v2 single-store
    /// (v0.13+).
    ///
    /// **CLI/gateway only, and CONSUMER-FREE since P55.** `/goal` is a real
    /// Hermes command in the TUI and gateway (`hermes_cli/commands.py:103` @
    /// `v2026.5.7`) but has never been an `acp_adapter/` name at any tag
    /// (`_COMMANDS`, `acp_adapter/commands.py:44-66` @ `v2026.9.7`), and
    /// Scarf's chat speaks ACP. Its last two readers were the optimistic goal
    /// PILL and the typed-command path that fed it; round-6 decision 3
    /// dropped both, because a pill for state no Hermes was asked to hold is
    /// Scarf inventing state (charter identity). Kept, unretired, because the
    /// floor is source-verified and because a future tag could add the name
    /// to the ACP table — the follow-on P55 filed is `t-e9c464a9`.
    public var hasGoals: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes kanban` task board CLI.
    ///
    /// **Floor v0.13.0, not v0.12.0** (P55 re-walk; charter C2 — the old doc
    /// cited a RELEASE, and the 0.12 release notes are exactly where the
    /// board's short life is recorded). Walked by OPENING both blobs:
    ///
    /// - **`v2026.4.30`** (`pyproject.toml` = **0.12.0**):
    ///   `hermes_cli/kanban.py` DOES NOT EXIST (`git ls-tree v2026.4.30
    ///   hermes_cli/kanban.py` lists nothing), and the string `kanban`
    ///   appears **zero** times in `hermes_cli/commands.py` and zero times
    ///   in `hermes_cli/main.py` — no `CommandDef`, no subparser, no
    ///   `cmd_kanban`.
    /// - **`v2026.5.7`** (**0.13.0**): `hermes_cli/kanban.py` exists,
    ///   `CommandDef("kanban", "Multi-profile collaboration board …")` is
    ///   `hermes_cli/commands.py:163`, `cmd_kanban` is `main.py:5278` and
    ///   the parser is built at `main.py:9232-9237`.
    ///
    /// The old floor was not cosmetic: on a 0.12 host every `hermes kanban …`
    /// argv Scarf sends is an UNKNOWN verb, which Hermes routes to the agent
    /// and exits 0 (charter C5), so the board read as *empty* rather than
    /// *unsupported* and the project-upgrade pass tried to mint a tenant
    /// through a verb that does not exist.
    ///
    /// **What each version range renders differently than Scarf's last
    /// release** (charter C1):
    /// - **< 0.12** — nothing changes; the flag was already `false`.
    /// - **0.12.x** — the five consumers now hide, exactly as they already
    ///   did below 0.12: the sidebar's Kanban entry
    ///   (`SidebarView.sections:54`), the cockpit's Board panel
    ///   (`ProjectCockpitView.visiblePanels:270`), the `hasKanban:` argument
    ///   to `AppCoordinator.upgradeProject` from both the cockpit
    ///   (`:248`) and the projects well (`SidebarProjectsWell:499`), which
    ///   skips `ProjectUpgradeService`'s tenant-mint step, and the iOS
    ///   project Kanban tab (`ProjectDetailView.visibleTabs:70`). This is
    ///   the intended correction: every one of those surfaces was driving a
    ///   verb the host does not have.
    /// - **>= 0.13** — byte-identical to the last release.
    public var hasKanban: Bool { atLeastSemver(0, 13, 0) }

    /// `/queue` slash command in the ACP adapter (v0.13+). Queues a prompt
    /// to run after the current turn completes without interrupting.
    ///
    /// Walked, not asserted — the same two-tag citation as ``hasACPSteer``,
    /// because the two arrived in the same commit: `queue` first appears at
    /// **v2026.5.7** (0.13.0) in `acp_adapter/server.py:171`, on the line
    /// below `steer` (`:170`), and `acp_adapter/` at **v2026.4.30** (0.12.x)
    /// has no `queue` slash command anywhere.
    public var hasACPQueue: Bool { atLeastSemver(0, 13, 0) }

    /// `/steer` EXISTS as an ACP slash command (v0.13+).
    ///
    /// Walked, not asserted: `steer` first appears at **v2026.5.7** (0.13.0)
    /// in `acp_adapter/server.py:170`, on the line above `queue` (`:171`) —
    /// the two arrived together — and `acp_adapter/` at **v2026.4.30**
    /// (0.12.x) has no `steer` anywhere. Below the floor the composer's
    /// `/steer` row was a dead name: over ACP an unknown command is not an
    /// error, `_handle_slash_command` returns `None` and the text falls
    /// through to the LLM (`acp_adapter/commands.py:88-95` @ `v2026.9.7`),
    /// so the row silently burned a turn (P34's finding, one row late).
    public var hasACPSteer: Bool { atLeastSemver(0, 13, 0) }

    // `hasACPSteerOnIdle` was RETIRED in P44 (round-4 decision 14). It was
    // `hasACPSteer` expressed a second time — the idle fallback
    // (`acp_adapter/server.py:812-820` @ `v2026.5.7`) shipped in the same
    // commit as the command itself (`:170`), so no host has one without the
    // other — and its only consumer was an arm of
    // `RichChatViewModel.disabledSlashCommandNames` that the P37 roster gate
    // had already made unreachable. A flag whose every reader is dead is not
    // defence in depth; it is a second place for the floor to drift.

    /// Kanban v0.13 reliability surface, as it actually exists at v2026.9.7:
    /// the `kanban diagnostics [--json]` subcommand over the rule engine
    /// (`hermes_cli/kanban_parser.py:251-256`, emitter
    /// `hermes_cli/kanban.py:627-695`, JSON at `:678-681`) and
    /// `kanban create --max-retries N`, the per-task failure limit
    /// (`hermes_cli/kanban_parser.py:176-181`, inside the `create`
    /// subcommand at `:148-204`). Neither `hallucination_gate`
    /// nor `auto_blocked_reason` appears anywhere at `v2026.9.7`, and the
    /// only "zombie" machinery is `reap_worker_zombies`
    /// (`hermes_cli/kanban_db_dispatch.py:190`), an internal child-process
    /// reap with no wire surface — P14 removed the Scarf surfaces that
    /// claimed all three. Nothing here is read through `kanban show`.
    public var hasKanbanDiagnostics: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes curator archive`, `prune`, and `list-archived` subcommands
    /// (v0.13+). The synchronous manual `hermes curator run` lives behind
    /// this flag too — pre-v0.13 `run` returns immediately and the work
    /// happens in the background.
    public var hasCuratorArchive: Bool { atLeastSemver(0, 13, 0) }

    /// Google Chat — 20th messaging-gateway platform (v0.13+).
    ///
    /// The floor lives in ``googleChatPlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasGoogleChatPlatform: Bool { atLeast(Self.googleChatPlatformFloor) }

    /// First Hermes version carrying the `google_chat` adapter — `plugins/platforms/google_chat/`
    /// first exists at tag v2026.5.7 (0.13.0).
    /// Shared by the flag above and `KnownPlatforms.all`'s `google_chat` row.
    public static let googleChatPlatformFloor = SemVer(major: 0, minor: 13, patch: 0)


    /// Cross-platform allowlist keys: `allowed_channels` (Slack / Mattermost
    /// / Google Chat), `allowed_chats` (Telegram / WhatsApp), `allowed_rooms`
    /// (Matrix / DingTalk). Settable per platform in `config.yaml` (v0.13+).
    ///
    /// **The v0.13 floor is KEPT, and it hides one key for one release**
    /// (round-6 decision 5; P55 tag walk). `gateway/config.py` at
    /// **`v2026.4.30`** (= 0.12.0) reads exactly ONE allowlist:
    /// Discord's `allowed_channels` (`:770-771`). Telegram there has only
    /// `group_allowed_chats` (`:828-832`) — NOT `allowed_chats` — and Slack,
    /// Mattermost, DingTalk and Matrix have no allowlist read at all. At
    /// **`v2026.5.7`** (= 0.13.0) the whole family arrives: Slack `:812-813`,
    /// Discord `:839-840`, Telegram `allowed_chats` `:902-903`, DingTalk
    /// `:991-992`, Mattermost `:1013-1014`, Matrix `allowed_rooms`
    /// `:1030-1031`.
    ///
    /// So the accepted cost of the single flag is narrower than the round-6
    /// report stated: on a **0.12.x** host, and only there, `GatewayBehaviorSection`
    /// (`:49`) and the iOS `SettingsView` (`:433`) hide the allowlist field
    /// for **Discord alone**, whose key that host does honour;
    /// `GatewayBehaviorViewModel.swift:154` correspondingly writes no list
    /// key. Every other platform's key genuinely does not exist there, and
    /// no per-platform flag is worth one key on one release.
    public var hasGatewayAllowlists: Bool { atLeastSemver(0, 13, 0) }

    /// `busy_ack_enabled` config to suppress per-message "agent is working…"
    /// acks across platforms (v0.13+).
    public var hasGatewayBusyAckToggle: Bool { atLeastSemver(0, 13, 0) }

    /// Per-platform `gateway_restart_notification` flag controls whether the
    /// platform posts a "Gateway restarted" notice on boot.
    ///
    /// Floor verified by walking the symbol back through every tag: the field
    /// lands in `gateway/config.py::PlatformConfig` at commit b71f80e6ce,
    /// first tagged v2026.5.7 = **0.13.0**, and it has defaulted to `True`
    /// since that first commit (`_coerce_bool(data.get(…), True)`) — which is
    /// why Scarf's editor defaults the toggle ON, not off.
    public var hasGatewayRestartNotification: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes gateway list` cross-profile status verb (v0.13+). Lets Scarf
    /// show which profile is currently running which platform.
    public var hasGatewayList: Bool { atLeastSemver(0, 13, 0) }

    /// MCP servers can use SSE transport (v0.13+).
    ///
    /// There is no `sse_read_timeout` CONFIG KEY to go with it, and there never
    /// was at any of the 32 tags (P24 removed the knob Scarf offered): Hermes
    /// hard-codes the value, `"sse_read_timeout": 300.0` in `sse_client`'s
    /// kwargs (`tools/mcp_tool_transport.py:352` @ v2026.9.7; the same literal
    /// in `tools/mcp_tool.py` at the v0.13 origin tag v2026.5.7), and reads no
    /// such key from an `mcp_servers` entry. The comment here used to claim the
    /// knob existed.
    public var hasMCPSSETransport: Bool { atLeastSemver(0, 13, 0) }

    /// Cron `--no-agent` mode for script-only watchdog jobs (v0.13+). Skips
    /// the AI call entirely — useful for keep-alive / periodic-check jobs.
    public var hasCronNoAgent: Bool { atLeastSemver(0, 13, 0) }

    /// Web Tools split into per-capability backend selection: `web_search`
    /// and `web_extract` can now use distinct backends (v0.13+). SearXNG
    /// joined as a search-only backend.
    public var hasWebToolsBackendSplit: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes profile create --no-skills` flag for empty profiles (v0.13+).
    public var hasProfileNoSkills: Bool { atLeastSemver(0, 13, 0) }

    /// Context compression count surfaced in the status feed (v0.13+).
    ///
    /// **Never reaches Scarf over ACP.** The adapter's `session/prompt`
    /// response builds `Usage` from five fields only — `prompt_tokens`,
    /// `completion_tokens`, `total_tokens`, `reasoning_tokens` and
    /// `cache_read_tokens`/`cached_tokens` — with no compression count at any
    /// tag: `acp_adapter/server.py:325-336` @ v2026.3.30 (0.6.0),
    /// `:1050-1059` @ v2026.5.7 (0.13.0, the claimed floor), `:917-924` @
    /// v2026.9.7 (0.21.1). So the chip this flag gates
    /// (`SessionInfoBar.swift`) is unreachable over ACP regardless of host
    /// version; the count stays 0 and the `> 0` test hides it. The flag and
    /// the tolerant decode in `ACPClient.prompt` are kept as the landing pad
    /// for a future gateway/`session/update` path — not because a v0.13 host
    /// sends the field.
    public var hasContextCompressionCount: Bool { atLeastSemver(0, 13, 0) }

    /// `/new` slash command accepts an optional session-name argument (v0.13+).
    public var hasNewWithSessionName: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes update --yes` / `-y` skips interactive prompts (v0.13+). Used
    /// by Scarf's "Update Hermes" affordance to run unattended.
    public var hasUpdateNonInteractive: Bool { atLeastSemver(0, 13, 0) }

    /// OpenRouter response caching toggle in `config.yaml` (v0.13+).
    public var hasOpenRouterResponseCache: Bool { atLeastSemver(0, 13, 0) }

    /// `image_gen.model` honored from `config.yaml` (v0.13+). Pre-v0.13 the
    /// value was advertised but ignored at runtime.
    public var hasImageGenModel: Bool { atLeastSemver(0, 13, 0) }

    /// `display.language` config key for static-message translation: zh / ja /
    /// de / es / fr / uk / tr (v0.13+).
    public var hasDisplayLanguage: Bool { atLeastSemver(0, 13, 0) }

    /// xAI Custom Voices — voice cloning support (v0.13+). Exposed in Scarf
    /// as a "Cloning supported" badge next to the xAI TTS provider entry.
    public var hasXAIVoiceCloning: Bool { atLeastSemver(0, 13, 0) }

    /// `video_analyze` tool — native video understanding on Gemini and
    /// compatible models (v0.13+). Hermes handles this transparently inside
    /// the agent loop; Scarf has no UI surface yet, but the flag lets future
    /// dashboards / activity views light up video-tool annotations.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasVideoAnalyze: Bool { atLeastSemver(0, 13, 0) }

    /// `transform_llm_output` plugin hook for shaping LLM output before the
    /// conversation receives it (v0.13+). Plugin-author concern.
    ///
    /// **No consumer yet** — a plugin-author concern. PluginsView does NOT
    /// surface it (nothing in Scarf mentions `transform_llm_output` outside
    /// this file); the earlier claim that it did was wrong.
    public var hasTransformLLMOutputHook: Bool { atLeastSemver(0, 13, 0) }

    // NOTE: `hasACPSetSessionModel` was RETIRED in P49 (round-5 decision 9).
    // ACP `session/set_model` is not a v0.13 surface: `set_session_model` is
    // defined in the adapter at the EARLIEST adapter tag and at every tag
    // since — `acp_adapter/server.py:466` @ v2026.3.17 (0.3.0), `:482` @
    // v2026.3.30 (0.6.0, Scarf's supported floor), `:929` @ v2026.9.7 — so
    // the flag's false branch only hid the model chip and the project model
    // binding from 0.6.0–0.12 hosts that have the RPC. A floor below the
    // v0.6.0 supported minimum is no floor at all (the P23/P15 rule), so the
    // model surfaces are unfloored like `reset` / `context` / `version`.

    // MARK: v0.14 (v2026.5.16) flags
    //
    // v0.14 is the Foundation Release — native Windows beta, PyPI install,
    // cold-start performance wave, OpenAI-compatible local proxy, two new
    // platforms (LINE + SimpleX Chat), two new providers (xAI OAuth +
    // NovitaAI), two new web-search backends (brave-free + ddgs), `/subgoal`
    // and a handful of new slash commands, per-turn file-mutation verifier,
    // ACP `--setup-browser`, and the Alibaba → Qwen Cloud display rename.
    //
    // Note: the v0.14 `/handoff` slash command is `cli_only` in Hermes's
    // command catalog (it hands the session off to a *messaging platform*,
    // not to a different model), so Scarf doesn't surface it in the ACP
    // chat menu. Model switching mid-chat remains the `session/set_model`
    // path, which is ungated (present at every adapter tag — see the
    // retirement note in the v0.13 group).

    /// `/subgoal` slash command — appends user-specified success criteria
    /// to the active `/goal` loop. Argument forms: `<text>`, `remove N`,
    /// `clear` (v0.14+). A TUI/gateway command, **not** an ACP one: like
    /// `/goal` it is absent from the adapter's `_COMMANDS` at every tag
    /// (`acp_adapter/commands.py:44-66` @ `v2026.9.7`). The doc here used to
    /// say "available in ACP and gateway contexts" and that Scarf renders
    /// the subgoals under the goal pill; P55 removed that pill (round-6
    /// decision 3) and the claim was never true of ACP.
    ///
    /// **No consumer** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasSubgoal: Bool { atLeastSemver(0, 14, 0) }

    // NOTE: `hasYOLOSlashCommand` was DELETED in P49 (round-5 decision 10).
    // It had no consumer after P34 removed the slash-menu row, and `/yolo` is
    // absent from `acp_adapter/` at every tag — so nothing in Scarf's ACP
    // surface could ever gate on it. Its floor, if it is ever needed again:
    // `CommandDef("yolo")` first appears at v2026.4.3 (0.7.0) and is absent
    // at v2026.3.30 (0.6.0).

    /// `/sessions` slash command — browse and resume previous sessions
    /// from inside an active chat (v0.14+).
    ///
    /// **CLI/gateway only, NOT ACP** (`hermes_cli/commands.py:148` @
    /// v2026.9.7; absent from `acp_adapter/` at every tag).
    ///
    /// **No consumer** — P34 removed its slash-menu row. Scarf exposes
    /// session browse via the sidebar, which is the native equivalent.
    /// Kept because the floor is source-verified and rediscovering it costs
    /// a tag walk.
    public var hasSessionsSlashCommand: Bool { atLeastSemver(0, 14, 0) }

    /// `/codex-runtime` slash command — toggle Codex app-server runtime
    /// for OpenAI/Codex models (v0.14+). Argument forms:
    /// `[auto|codex_app_server]`.
    ///
    /// **CLI/gateway only, NOT ACP** (`hermes_cli/commands.py:156-158` @
    /// v2026.9.7, alias `codex_runtime`; absent from `acp_adapter/` at
    /// every tag).
    ///
    /// **No consumer** — P34 removed its slash-menu row. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasCodexRuntimeSlashCommand: Bool { atLeastSemver(0, 14, 0) }

    /// xAI Grok OAuth (SuperGrok) provider — overlay-only, OAuth-external
    /// auth, base URL `https://api.x.ai/v1` (v0.14+). Wire ID is
    /// `xai-oauth` (canonical); `x-ai-oauth` / `grok-oauth` /
    /// `xai-grok-oauth` are accepted aliases.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasGrokOAuthProvider: Bool { atLeastSemver(0, 14, 0) }

    /// NovitaAI inference provider (v0.14+). Overlay-only, API-key auth,
    /// base URL `https://api.novita.ai/v3/openai`. Wire ID is `novita`
    /// (canonical); `novita-ai` / `novitaai` are aliases.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasNovitaProvider: Bool { atLeastSemver(0, 14, 0) }

    /// LINE Messaging API — 21st gateway platform (v0.14+). Wire ID `line`.
    ///
    /// The floor lives in ``linePlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasLINEPlatform: Bool { atLeast(Self.linePlatformFloor) }

    /// First Hermes version carrying the `line` adapter — `plugins/platforms/line/` first exists at
    /// tag v2026.5.16 (0.14.0).
    /// Shared by the flag above and `KnownPlatforms.all`'s `line` row.
    public static let linePlatformFloor = SemVer(major: 0, minor: 14, patch: 0)


    /// SimpleX Chat — 22nd gateway platform (v0.14+). Wire ID `simplex`.
    /// Requires a local `simplex-chat` daemon running in WebSocket mode.
    ///
    /// The floor lives in ``simplexPlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasSimpleXPlatform: Bool { atLeast(Self.simplexPlatformFloor) }

    /// First Hermes version carrying the `simplex` adapter — `plugins/platforms/simplex/` first exists
    /// at tag v2026.5.16 (0.14.0).
    /// Shared by the flag above and `KnownPlatforms.all`'s `simplex` row.
    public static let simplexPlatformFloor = SemVer(major: 0, minor: 14, patch: 0)


    /// Brave Search (free tier) web-search backend (v0.14+). Wire ID
    /// `brave-free`. Honors a `BRAVE_SEARCH_API_KEY` env var for premium
    /// quotas; works anonymously for basic queries.
    public var hasBraveFreeSearchBackend: Bool { atLeastSemver(0, 14, 0) }

    /// DuckDuckGo (DDGS) web-search backend (v0.14+). Wire ID `ddgs`.
    /// Anonymous; uses the `ddgs` Python package which Hermes installs
    /// lazily on first use.
    public var hasDDGSearchBackend: Bool { atLeastSemver(0, 14, 0) }

    /// MCP servers can advertise `supports_parallel_tool_calls` so the
    /// agent batches concurrent tool calls instead of serializing them
    /// (v0.14+). Settings surface only — runtime behavior is server-side.
    public var hasMCPParallelToolCalls: Bool { atLeastSemver(0, 14, 0) }

    /// `docker_extra_args` config key — extra flags passed verbatim to
    /// `docker run` for the docker-backed terminal backend (v0.14+).
    /// Stored as a list of strings; default is empty list.
    public var hasDockerExtraArgs: Bool { atLeastSemver(0, 14, 0) }

    /// `display.timestamps` config toggle — show per-message timestamps in
    /// chat output (v0.14+). Mac surface adds the toggle in Settings →
    /// General.
    public var hasDisplayTimestamps: Bool { atLeastSemver(0, 14, 0) }

    /// Cron jobs accept `deliver=all` for fan-out delivery to every
    /// connected channel (v0.14+). Pre-v0.14 hosts only accepted a
    /// specific platform string.
    public var hasCronDeliverAll: Bool { atLeastSemver(0, 14, 0) }

    /// Whether `hermes cron create --deliver <value>` is accepted by this
    /// host. Only the v0.14+ fan-out sentinel `all` is version-gated
    /// (`hasCronDeliverAll`); nil/empty (no `--deliver` flag) and any specific
    /// platform (`discord`, `discord:chan`, `telegram:chat`, …) are baseline
    /// and accepted everywhere. Forwarding an unsupported `--deliver all` makes
    /// argparse reject the whole `cron create`, so every Scarf cron-create path
    /// that copies a job to another host (fleet apply-cron, template install)
    /// gates on this.
    /// v0.20.6 addendum: `bot-chat` / `bot-chat:<profile>` is the second
    /// version-gated sentinel. A pre-v0.20.6 Hermes resolves it as a
    /// platform name and fails the whole `cron create`, so it gets the
    /// same treatment as `all` — including the `:profile` suffix form,
    /// which the prefix check below covers.
    public func supportsCronDeliver(_ deliver: String?) -> Bool {
        guard let deliver else { return true }
        if deliver == "all" { return hasCronDeliverAll }
        if deliver == "bot-chat" || deliver.hasPrefix("bot-chat:") { return hasCronBotChatDelivery }
        return true
    }

    /// Discord plugin reads recent channel history when joining a thread
    /// (default on in v0.14+). Scarf surfaces the toggle so users can
    /// disable the backfill for noisy channels.
    public var hasDiscordHistoryBackfill: Bool { atLeastSemver(0, 14, 0) }

    /// OpenRouter Pareto Code router knob `openrouter.min_coding_score`
    /// (0.0–1.0, default 0.65) — routes to the cheapest model meeting the
    /// quality bar (v0.14+). Used together with the
    /// `openrouter/pareto-code` model alias.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasOpenRouterParetoCoder: Bool { atLeastSemver(0, 14, 0) }

    /// Custom provider `api_mode` field — explicit `chat_completions` /
    /// `anthropic_messages` / etc. selection persisted per provider
    /// (v0.14+). Pre-v0.14 hosts inferred from base URL.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasCustomProviderAPIMode: Bool { atLeastSemver(0, 14, 0) }

    /// Plugin `tool_override` flag — plugins can replace built-in tools
    /// (v0.14+). Scarf reads the manifest field to render a badge in
    /// `PluginsView`.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasPluginToolOverride: Bool { atLeastSemver(0, 14, 0) }

    /// `hermes plugins enable <name> --allow-tool-override` /
    /// `--no-allow-tool-override` — the non-interactive consent pair that
    /// grants (or refuses) a plugin permission to replace built-in tools
    /// like `shell_exec` / `write_file`.
    ///
    /// **Distinct from `hasPluginToolOverride` (v0.14), and later:** the
    /// v0.14 flag is about the plugin *manifest* field Scarf renders as a
    /// badge. The CLI flags that let Scarf answer the consent prompt
    /// without a tty first appear in the `plugins enable` parser at
    /// v2026.7.1 = **v0.18.0** — verified absent at v2026.6.19 (v0.17.0)
    /// and present at v2026.7.1 (`git grep allow-tool-override` over
    /// `hermes_cli/`). On older hosts `plugins enable` prompts on stdin
    /// and Scarf must not offer the grant affordance at all.
    public var hasPluginEnableToolOverrideFlag: Bool { atLeastSemver(0, 18, 0) }

    /// `hermes plugins list --json` — machine-readable activation state
    /// (`[{name, status, version, description, source}]`, where `status`
    /// is `enabled` / `disabled` / `not enabled`).
    ///
    /// Version floor verified by walking the `plugins list` subparser
    /// across tags: the `--json` argument is absent at v2026.5.29.2
    /// (v0.15.2) and present at v2026.6.5 (**v0.16.0**). Pre-v0.16 hosts
    /// reject the flag at argparse time and the whole command exits
    /// nonzero, so callers must fall back to reading `plugins.enabled` /
    /// `plugins.disabled` out of config.yaml — which is the same source
    /// `_plugin_status` reads, so both paths agree exactly.
    public var hasPluginsListJSON: Bool { atLeastSemver(0, 16, 0) }

    /// `hermes proxy` CLI verb — OpenAI-compatible local proxy that
    /// attaches OAuth-authenticated provider credentials to outbound
    /// requests (v0.14+). Default port 8645, default adapter `nous`.
    /// Scarf wraps `hermes proxy start` / `status` / `providers` in a
    /// dedicated sidebar destination.
    public var hasHermesProxy: Bool { atLeastSemver(0, 14, 0) }

    /// `hermes acp --setup-browser` flag — one-shot setup verb that
    /// installs Chromium and provisions Playwright for browser tools
    /// (v0.14+). Surfaced in the Health view as a "Run setup" button.
    public var hasACPSetupBrowser: Bool { atLeastSemver(0, 14, 0) }

    /// Per-turn file-mutation verifier footer — Hermes appends a summary
    /// of files written on disk to every assistant turn that mutated
    /// files (v0.14+; default on via `file_mutation_verifier` config).
    /// Scarf detects and styles the block in chat output.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasFileMutationVerifier: Bool { atLeastSemver(0, 14, 0) }

    /// Hermes surfaces a YOLO mode warning in its banner + status bar
    /// when `agent.approval_mode = yolo` (v0.14+). Scarf mirrors with
    /// a chat-header warning badge when the user's config opts in.
    public var hasYOLOWarning: Bool { atLeastSemver(0, 14, 0) }

    /// Alibaba Cloud display name has been renamed to "Qwen Cloud" in
    /// Hermes's provider picker (v0.14+). Wire ID remains `alibaba`;
    /// existing config keys still work. Scarf mirrors the display
    /// rename in the catalog so users see consistent naming across
    /// CLI and GUI.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasQwenCloudDisplayName: Bool { atLeastSemver(0, 14, 0) }

    /// Cross-session 1-hour Claude prompt cache shared across sessions
    /// on Anthropic / OpenRouter / Nous Portal (v0.14+). Server-side
    /// behavior; Scarf surfaces it as a documentation note in Settings →
    /// Prompt Caching when on a v0.14 host.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasCrossSessionClaudeCache: Bool { atLeastSemver(0, 14, 0) }

    // MARK: v0.15 (v2026.5.28) flags
    //
    // v0.15 is the Velocity Release. Flags here gate the v0.15 surfaces
    // Scarf adopts: the chat-scoped Kanban surface, the Kanban maturation
    // wave, ntfy, xAI web search + TTS speech tags, Azure Entra auth,
    // Bitwarden secrets, `hermes audit`, xAI model-retirement migration,
    // MCP mTLS + catalog, skill bundles, and ACP session edit-approval
    // modes. Catalog-sync changes (the `openai-api` overlay, Krea image
    // models, xAI retired-model aliases, Vercel removal) are unconditional
    // and carry no flag.

    /// Kanban tasks carry an originating ACP `session_id`, and
    /// `hermes kanban list --session <id>` filters by it (v0.15+). The
    /// ACP adapter stamps `HERMES_SESSION_ID` around the agent loop, so
    /// `kanban_create` links every task to its originating chat with no
    /// agent flag discipline. Lets the chat-scoped board filter precisely
    /// instead of the old tenant + time-window heuristic; gates the
    /// chat-header Kanban chip + chat → board handoff.
    public var hasKanbanSessionFilter: Bool { atLeastSemver(0, 15, 0) }

    /// The v0.15 Kanban maturation wave: `list --sort`, `promote`,
    /// `archive --rm` purge, `schedule` verb + `scheduled`/`review`
    /// statuses, worktree `--branch`, read-only `model_override`, the
    /// `swarm` topology helper, and the `--board` multi-board flag. Single
    /// gate for the whole wave — pre-v0.15 hosts keep the v0.12 board.
    public var hasKanbanV015: Bool { atLeastSemver(0, 15, 0) }

    /// xAI Web Search as a `web.search_backend` value (`xai`).
    /// Reuses Grok OAuth / `XAI_API_KEY`; no new env var.
    public var hasXAIWebSearchBackend: Bool { atLeastSemver(0, 15, 0) }

    /// ntfy — 23rd messaging platform (push notifications via a topic URL,
    /// no account). Config under `platforms.ntfy.extra`.
    ///
    /// The floor lives in ``ntfyPlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasNtfyPlatform: Bool { atLeast(Self.ntfyPlatformFloor) }

    /// First Hermes version carrying the `ntfy` adapter — `plugins/platforms/ntfy/` first exists at
    /// tag v2026.5.28 (0.15.0).
    /// Shared by the flag above and `KnownPlatforms.all`'s `ntfy` row.
    public static let ntfyPlatformFloor = SemVer(major: 0, minor: 15, patch: 0)


    /// `discord.allow_any_attachment` is read by the adapter — a WINDOW, not
    /// a floor. Round-5, P51.
    ///
    /// This is the first flag in the file whose upper bound is load-bearing,
    /// so the walk is written out. `_discord_allow_any_attachment` is defined
    /// AND CALLED (`plugins/platforms/discord/adapter.py:3622`, called at
    /// `:4608` and `:4717`, gating at `:4719`) from **v2026.5.28 (0.15.0)**;
    /// it is absent at v2026.5.16 and before. At **v2026.7.1 (0.18.0)** the
    /// two call sites are GONE while the getter itself lingers, so the key
    /// stops deciding anything — and at `v2026.9.7` the getter is deleted
    /// too: the key survives only as a schema default
    /// (`hermes_cli/config_defaults.py:1448`), and the tag's own docs say so
    /// in as many words (`website/docs/user-guide/messaging/discord.md:703`:
    /// the flag "is now a no-op — any file type is always accepted").
    ///
    /// Counted by CALL SITE, not by definition: a getter nothing calls is
    /// exactly the dead row C1 exists to keep off screen, and grepping the
    /// symbol would have put the window's end three releases late. Tags
    /// walked one by one, `self._discord_allow_any_attachment()` call count:
    /// v2026.5.16 → absent, v2026.5.28 → 2, v2026.5.29 → 2, v2026.6.5 → 2,
    /// v2026.6.19 → 2, v2026.7.1 → 0, and 0 at every tag through v2026.9.7.
    ///
    /// Retiring the row outright was the alternative and it is the wrong one:
    /// a v0.15–v0.17 host honours the toggle, and C1's "a pre-target host
    /// must render byte-identical to the prior Scarf release" is exactly
    /// about those users. The row hides where it does nothing, and the
    /// writer follows the row (`DiscordSetupViewModel.save`).
    ///
    /// **What this REMOVES, owned plainly (round-5 P52).** The row was
    /// previously ungated, so it rendered on every host — and this window
    /// takes it away at BOTH ends, not just above v0.18. On a v0.18+ host and
    /// on a ≤v0.14 host alike, a control the previous Scarf release showed is
    /// now gone. That is intended, and it is not a C1 violation, because C1
    /// protects a host that HONOURS a setting: at ≤v0.14 the getter does not
    /// exist to read the key, and at v0.18+ nothing calls it — Hermes ships
    /// the key as a schema default whose own comment says
    /// `# DEPRECATED no-op (uploads are always cached; messaging auth is the
    /// gate). Kept so existing configs don't error.`
    /// (`hermes_cli/config_defaults.py:1446-1448` @ v2026.9.7). A toggle that
    /// writes a key nobody reads is the dead row, not the preserved one.
    public var hasDiscordAllowAnyAttachment: Bool {
        atLeastSemver(0, 15, 0) && !atLeastSemver(0, 18, 0)
    }

    /// Opt-in `tts.xai.auto_speech_tags` — inserts light `[pause]` tags
    /// between sentences/paragraphs for more natural xAI TTS. Default OFF.
    public var hasXAITTSAutoSpeechTags: Bool { atLeastSemver(0, 15, 0) }

    /// Microsoft Entra ID auth for Azure AI Foundry — config knob
    /// `model.auth_mode = "entra_id"` (+ `model.entra.scope`); credentials
    /// flow through the Azure SDK env chain (`DefaultAzureCredential`).
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasAzureEntraAuth: Bool { atLeastSemver(0, 15, 0) }

    /// Bitwarden Secrets Manager — `secrets.bitwarden.*` config + a
    /// bootstrap token (`BWS_ACCESS_TOKEN`) replacing per-provider keys.
    public var hasBitwarden: Bool { atLeastSemver(0, 15, 0) }

    /// `hermes security audit` — on-demand OSV.dev supply-chain audit verb.
    ///
    /// **The verb is `hermes security audit`, not `hermes audit`** (P55 doc
    /// fix; charter C5). `audit` is a SUBCOMMAND of `security`
    /// (`hermes_cli/main.py:12358` `dest="security_command"`, the `"audit"`
    /// sub-parser at `:12363`, dispatched by `cmd_security` at `:6218-6225`,
    /// all @ **`v2026.5.28`**); a bare `hermes audit` is an unknown verb and
    /// would route to the agent at exit 0. `HealthViewModel.runSecurityAudit`
    /// sends the correct argv — only this doc named the wrong one.
    ///
    /// **Floor v0.15.0, re-walked and unchanged.** `hermes_cli/security_audit.py`
    /// is absent at `v2026.5.16` (`pyproject.toml` = 0.14.0) and present at
    /// `v2026.5.28` (= **0.15.0**), whose blob is byte-identical to the one at
    /// `v2026.5.29` (0.15.1) that `HealthViewModel`'s parser comment cites.
    /// No version range renders differently than the last release.
    public var hasHermesAudit: Bool { atLeastSemver(0, 15, 0) }

    /// xAI May-15 model retirement detection + `hermes migrate xai`
    /// one-shot config migration to the supported successor model.
    public var hasXAIModelRetirement: Bool { atLeastSemver(0, 15, 0) }

    /// mTLS / TLS client certificate support for HTTP + SSE MCP servers —
    /// `client_cert` / `client_key` / `ssl_verify` keys on the server entry.
    public var hasMCPClientCerts: Bool { atLeastSemver(0, 15, 0) }

    /// Nous-approved MCP catalog + `hermes mcp` picker (catalog is text
    /// output — no `--json`). Manifests at `optional-mcps/<name>/`.
    public var hasMCPCatalog: Bool { atLeastSemver(0, 15, 0) }

    /// Skill bundles — named groups of skills loaded by one `/<name>`
    /// slash command. Enumerated via `hermes bundles list`; stored at
    /// `~/.hermes/skill-bundles/*.yaml`.
    public var hasSkillBundles: Bool { atLeastSemver(0, 15, 0) }

    /// Skills Hub index-level freshness (`generated_at` + `skill_count` in
    /// skills-index.json). Index-level only — no per-skill staleness.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasSkillHubFreshness: Bool { atLeastSemver(0, 15, 0) }

    /// ACP session edit auto-approval modes — `session/set_mode` with
    /// mode IDs `default` / `accept_edits` / `dont_ask` (advertised in
    /// `session/new`'s `modes`). Sensitive paths always still prompt.
    public var hasSessionEditAutoApproval: Bool { atLeastSemver(0, 15, 0) }

    // MARK: v0.16 (v2026.6.5) flags

    // `hasSessionsRename` used to live here at a v0.16 floor. It is gone:
    // `sessions rename` exists at EVERY tagged Hermes, including the oldest
    // one in the repo — `sessions_subparsers.add_parser("rename", …)` at
    // `hermes_cli/main.py:2373`, tag v2026.3.12 (`pyproject.toml` = `0.2.0`)
    // — and at every tag since (relocated to
    // `hermes_cli/subcommands/sessions.py:210` by the v0.17 modularisation).
    // A floor below Scarf's v0.6.0 supported minimum is no floor at all
    // (the P15 `--clear-skills` rule), and the spurious one hid the rename
    // context-menu item from every 0.12–0.15 host that has the verb.

    /// `hermes sessions optimize` — compact the FTS index and VACUUM the
    /// sessions database (v0.16+). Exposed in the Health / Maintenance view.
    public var hasSessionsOptimize: Bool { atLeastSemver(0, 16, 0) }

    /// Kanban tasks carry `goal_mode` (boolean) and `goal_max_turns` (optional
    /// integer) columns for Ralph-style goal loops (v0.16+). Lets the kanban
    /// surface allow users to dispatch a task as a persistent goal-seeking
    /// worker with a turn budget instead of a one-shot execution.
    ///
    /// **No consumer yet** — the goal-mode surface it gated was deleted in the
    /// whole-surface audit (it read a field Hermes never emitted), so this flag
    /// is currently unread. Kept as the verified floor for a future one.
    public var hasKanbanGoalMode: Bool { atLeastSemver(0, 16, 0) }

    // NOTE: `hasInsightsCommand` was DELETED in P49's re-walk of this MARK
    // group. `hermes insights` is NOT a v0.16 surface: `cmd_insights` is
    // `hermes_cli/main.py:4634` (registered at `:4627`, and in the verb list
    // at `:3291`) at **v2026.3.30 = 0.6.0**, Scarf's supported minimum — so
    // the flag was false for no supported host. A floor below the supported
    // minimum is no floor at all (the P15/P23 rule) and the flag had no
    // consumer, so it is gone rather than re-floored.

    /// `hermes dashboard` — web-UI backend verb for the desktop dashboard
    /// application. Scarf doesn't directly invoke this; it documents the
    /// version boundary for dashboard-aware installs.
    ///
    /// **Floor v0.9.0, not v0.16.** `def cmd_dashboard(args)` is
    /// `hermes_cli/main.py:4458` at tag **v2026.4.13** (`pyproject.toml` =
    /// `0.9.0`), with the subcommand registered at `:4180` / `:5978`; the
    /// string `dashboard` occurs nowhere in `hermes_cli/main.py` at
    /// v2026.4.8 (0.8.0). The v0.16 floor came from the MARK group's name,
    /// which the P23 lesson says is not evidence for its members.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasDashboardCommand: Bool { atLeastSemver(0, 9, 0) }

    // MARK: v0.17 (v2026.6.19) flags

    /// `curator.consolidate` config key — the LLM skill-consolidation pass is
    /// now OPT-IN (default off); deterministic pruning stays default-on
    /// (v0.17+). Surfaced as a Settings toggle so users can re-enable the merge
    /// pass that ran automatically before v0.17.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasCuratorConsolidate: Bool { atLeastSemver(0, 17, 0) }

    /// `max_concurrent_sessions` top-level config key — optional cap on
    /// simultaneously-active chat sessions, with automatic cleanup of the
    /// oldest when exceeded (v0.17+). `0`/empty means unbounded.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasMaxConcurrentSessions: Bool { atLeastSemver(0, 17, 0) }

    /// `photon` gateway platform — iMessage via Photon Spectrum (device-code
    /// OAuth + local gRPC sidecar), 24th platform (v0.17+).
    ///
    /// The floor lives in ``photonPlatformFloor`` so the Platforms roster row
    /// (`KnownPlatforms.all`, which gates on a `SemVer` rather than a Bool)
    /// and this flag cannot drift apart.
    public var hasPhotonPlatform: Bool { atLeast(Self.photonPlatformFloor) }

    /// First Hermes version carrying the `photon` gateway adapter. Shared by
    /// ``hasPhotonPlatform`` and `KnownPlatforms.all`'s `photon` row.
    public static let photonPlatformFloor = SemVer(major: 0, minor: 17, patch: 0)

    /// First Hermes version carrying the `buzz` adapter —
    /// `plugins/platforms/buzz/` first exists at tag v2026.7.30, whose
    /// `pyproject.toml` reads `version = "0.19.1"` (NOT v0.20, which is what
    /// the roster's own section comment used to claim). Consumed only by
    /// `KnownPlatforms.all`'s `buzz` row; there is no `hasBuzzPlatform` flag
    /// because nothing but the roster needs it.
    public static let buzzPlatformFloor = SemVer(major: 0, minor: 19, patch: 1)

    /// `whatsapp_cloud` gateway platform — WhatsApp Business Cloud API (Meta's
    /// hosted webhook path, distinct from the older `whatsapp` web bridge),
    /// 25th platform (v0.17+).
    ///
    /// The floor lives in ``whatsAppCloudPlatformFloor`` so the Platforms roster row
    /// (`HermesToolPlatform`, which gates on a `SemVer`) and this flag
    /// cannot drift apart.
    public var hasWhatsAppCloudPlatform: Bool { atLeast(Self.whatsAppCloudPlatformFloor) }

    /// First Hermes version carrying the `whatsapp_cloud` adapter — `gateway/platforms/whatsapp_cloud.py`
    /// first exists at tag v2026.6.19 (0.17.0), the same tag as
    /// ``photonPlatformFloor``.
    /// Shared by the flag above and `KnownPlatforms.all`'s `whatsapp_cloud` row.
    public static let whatsAppCloudPlatformFloor = SemVer(major: 0, minor: 17, patch: 0)


    /// Telegram `rich_messages` (Bot API 10.1, default-on) + `status_indicator`
    /// (opt-in presence label) per-platform config keys (v0.17+).
    public var hasTelegramRichMessages: Bool { atLeastSemver(0, 17, 0) }

    // MARK: v0.18 (v2026.7.1) flags
    //
    // v0.18's client-relevant surface is deliberately thin: the
    // `messages.compacted` column is schema-detected (see
    // `HermesQueryBackend.hasCompactedColumn`), and the provider-table
    // changes (MoA overlay, google-gemini-cli → vertex) are
    // catalog-sync changes that carry no flag by convention.

    /// Per-job cron `attach_to_session` (bool) — mirrors a job's
    /// delivery output into the target chat session's transcript,
    /// overriding the global `cron.mirror_delivery` config (v0.18+).
    /// Scarf round-trips the field on all hosts (unknown keys are
    /// simply absent pre-v0.18); gate any future editor UI on this.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasCronAttachToSession: Bool { atLeastSemver(0, 18, 0) }

    /// `hermes mcp reauth [name|--all]` — refresh expired MCP OAuth
    /// tokens without re-adding the server (v0.18+).
    public var hasMCPReauth: Bool { atLeastSemver(0, 18, 0) }

    /// `auxiliary.title_generation.language` — force generated chat titles
    /// into a specific language regardless of the chat's own language
    /// (v0.18+, hermes-agent commit cf58f1a520 "support language-aware
    /// title generation", first released v2026.7.1 = v0.18.0). The rest of
    /// the `title_generation` block predates version tracking and is
    /// ungated.
    public var hasTitleGenerationLanguage: Bool { atLeastSemver(0, 18, 0) }

    // MARK: v0.19 (v2026.7.20) flags

    /// `hermes config get <key>` / `hermes config unset <key>` subcommands
    /// (v0.19+, `hermes_cli/config.py:unset_config_value`, introduced by
    /// Hermes commit 53adb3fd97, first released in v2026.7.20 = 0.19.0).
    /// Pre-v0.19 hosts only have `config set`, so any UI affordance that
    /// removes a key — as opposed to writing an empty value, which is NOT
    /// equivalent for keys like `browser.cloud_provider` — must hide itself
    /// behind this flag rather than issue a command that exits non-zero.
    public var hasConfigUnset: Bool { atLeastSemver(0, 19, 0) }

    /// `auxiliary.<task>.reasoning_effort` — per-task thinking-level
    /// override on every auxiliary task (v0.19+, hermes-agent commit
    /// df5700ebe3 "per-task reasoning_effort for auxiliary models" #64597,
    /// first released v2026.7.20 = 0.19.0 — the same tag that introduced
    /// `hasConfigUnset`).
    public var hasAuxiliaryReasoningEffort: Bool { atLeastSemver(0, 19, 0) }

    // MARK: Voice provider roster floors
    //
    // Hermes keeps its own authoritative roster of built-in speech providers,
    // and Scarf's two pickers mirror it. The sets are
    // `BUILTIN_TTS_PROVIDERS` (`tools/tts_command_provider.py:269` @
    // v2026.9.7, mirrored by `agent/tts_registry.py::_BUILTIN_NAMES`) and
    // `BUILTIN_STT_PROVIDERS` (`tools/transcription_common.py:45`, mirrored by
    // `agent/transcription_registry.py::_BUILTIN_NAMES`) — Hermes has a test
    // of its own that fails when the two copies drift, so either is citable.
    //
    // Membership was walked across all 32 `v2026.*` tags by extracting the
    // frozenset literal at each one, which is what these floors are:
    //
    //   TTS  edge/elevenlabs/openai/minimax/mistral/neutts/piper/xai/gemini/
    //        kittentts   first DISPATCHED: v2026.4.23 (v0.11.0); the
    //                    frozenset itself only exists from v2026.4.30
    //                    (v0.12.0) — see `hasGeminiKittenTTS`
    //   TTS  deepinfra   first set: v2026.7.20 (v0.19.0)   [hasDeepInfraTTS]
    //   STT  local/local_command/groq/openai/mistral/xai
    //                    first set: v2026.5.28 (v0.15.0)
    //   STT  elevenlabs, deepinfra
    //                    first set: v2026.7.20 (v0.19.0)
    //
    // Only the members whose registration POSTDATES the v0.6.0 supported
    // minimum need a flag; the v0.11.0 group gets one because v0.6.0–v0.10.0
    // hosts are supported and have no TTS roster at all.

    /// `gemini` and `kittentts` as `tts.provider` values.
    ///
    /// **The floor is v0.11.0, but `BUILTIN_TTS_PROVIDERS` is not the evidence
    /// for it** — the round-2 doc claimed the constant's "very first tagged
    /// form" is v2026.4.23, and it is not: `BUILTIN_TTS_PROVIDERS` does not
    /// exist at that tag at all, its first tagged form being
    /// `tools/tts_tool.py:316` @ **v2026.4.30 (0.12.0)**. A floor whose cited
    /// constant postdates it by a release cannot be re-verified from the
    /// comment (C2).
    ///
    /// The real evidence is the provider DISPATCH, which is what actually
    /// decides whether a `tts.provider` value does anything: the arms
    /// `elif provider == "gemini"` and `elif provider == "kittentts"` are
    /// `tools/tts_tool.py:1024` and `:1038` @ **v2026.4.23 (0.11.0)**. At
    /// v2026.4.16 (0.10.0) `tools/tts_tool.py` exists but contains neither
    /// name anywhere, so v0.11.0 is a real floor and not an artefact of a
    /// constant moving.
    ///
    /// Both names are in `BUILTIN_TTS_PROVIDERS` from the moment it exists
    /// (v0.12.0) through v2026.9.7, so the roster and the dispatch agree
    /// everywhere above the floor.
    public var hasGeminiKittenTTS: Bool { isV011OrLater }

    /// `elevenlabs` and `deepinfra` as `stt.provider` values —
    /// `BUILTIN_STT_PROVIDERS` gains both at v2026.7.20 (v0.19.0), the same
    /// tag as `hasDeepInfraTTS`; v2026.7.7.2 (v0.18.2) has neither. Every
    /// later tag through v2026.9.7 keeps them. Verified at the mirror too:
    /// `agent/transcription_registry.py::_BUILTIN_NAMES` (`:40`) lists
    /// `elevenlabs` (`:47`) and `deepinfra` (`:48`) at v2026.7.20 and neither
    /// at v2026.7.7.2.
    public var hasElevenLabsDeepInfraSTT: Bool { atLeastSemver(0, 19, 0) }

    /// `tts.deepinfra.{model,voice}` — DeepInfra as a TTS backend, alongside
    /// its existing `stt.deepinfra.model` sibling (v0.19+, hermes-agent
    /// commit fe002eb124 "feat(providers): Support DeepInfra as an LLM
    /// provider" — the same commit scaffolded the `tts`/`stt` DeepInfra
    /// blocks — first released v2026.7.20 = 0.19.0).
    public var hasDeepInfraTTS: Bool { atLeastSemver(0, 19, 0) }

    /// `tts.xai.{language,speed,optimize_streaming_latency,sample_rate,
    /// bit_rate}` — the rest of xAI TTS's tunable params beyond voice/model
    /// (v0.19+, hermes-agent commit 5c6499ce4d "feat: surface all xAI TTS
    /// params in desktop GUI config", first released v2026.7.20 = 0.19.0).
    /// That commit also added `tts.xai.text_normalization`, but commit
    /// 6bb8a0aef1 dropped it again before any tagged release shipped it
    /// ("not honored by the xAI TTS backend") — Scarf never surfaces that
    /// key. `auto_speech_tags` predates this flag; see
    /// `hasXAITTSAutoSpeechTags`.
    public var hasXAITTSAdvancedParams: Bool { atLeastSemver(0, 19, 0) }

    /// Scarf's "Hermes Voice" playback engine: `HermesSpeechService` calls
    /// `tools.tts_tool.text_to_speech_tool(text, output_path=…)` on the
    /// server and reads back the files its envelope names. Gates the
    /// Settings → Voice "Playback Engine" picker and the synthesis path;
    /// below the floor the picker is hidden and the speaker button uses the
    /// system voice exactly as before.
    ///
    /// **Floor v0.20.1 (v2026.8.13)** — the first tag where all three
    /// things the service depends on hold (walked across every `v2026.*`
    /// tag from v2026.3.30 = 0.6.0):
    ///  - `output_path` kwarg: present at every tag
    ///    (`tools/tts_tool.py:347-349` @ v2026.3.30 through `:400-402` @
    ///    v2026.9.14);
    ///  - `provider` kwarg: first at **v2026.7.30 (0.19.1)**
    ///    (`tools/tts_tool.py:2781-2786`), absent at v2026.7.20 (0.19.0)
    ///    whose signature is `(text, output_path)` only (`:2284-2286`).
    ///    The service does not pass it (see
    ///    `HermesSpeechService.toolPythonScript`), but it is part of the
    ///    tool contract the floor was asked to cover;
    ///  - the `file_path` + `file_paths` long-form envelope and its
    ///    `<stem>.chunkNNN` / `<stem>.partNN` naming: first at **v2026.8.13
    ///    (0.20.1)** (`tools/tts_tool.py:3612-3613` chunk names, `:3669-3670`
    ///    envelope, part names `:1691-1692`); at v2026.8.3 (0.20.0) the
    ///    string `"file_paths"` does not occur in the file and the envelope
    ///    is the single-file `"file_path": file_str` (`:3137`).
    /// Unchanged in shape through v2026.9.14 (`tools/tts_tool.py:381`
    /// chunks, `:446` envelope; `tools/tts_tool_delivery.py:413` parts).
    public var hasHermesSpeechSynthesis: Bool { isV0201OrLater }

    // MARK: v0.20 (v2026.8.3) flags
    //
    // `hasCompressCommand` used to live here, claiming ACP's `/compact` was
    // renamed `/compress` at v0.20. That floor was wrong, but so was the
    // round-2 conclusion that the answer is NO gate: the flag moved to
    // ``hasACPCompressSpelling`` below, floored at v0.19.1, because the
    // renaming is real and happened inside the supported window — it just
    // happened in the ACP adapter rather than in `hermes_cli/commands.py`.
    // See that flag's doc for the 32-tag walk.

    /// `hermes curator adopt` / `hermes curator list-unmanaged` — adopt
    /// stray notes into curator management and list unmanaged ones.
    ///
    /// **Floor v0.19.1, not v0.20.** `_cmd_adopt` is
    /// `hermes_cli/curator.py:344` and the `list-unmanaged` parser `:748` at
    /// tag **v2026.7.30** (`pyproject.toml` = `0.19.1`); neither name occurs
    /// anywhere in `hermes_cli/curator.py` at v2026.7.20 (0.19.0). Same
    /// v0.20-audit mis-read as the `isV0191OrLater` cluster below.
    public var hasCuratorAdopt: Bool { isV0191OrLater }

    /// `hermes approvals suggest` — suggest an approval decision for a
    /// pending request.
    ///
    /// **Floor v0.19.1, not v0.20.** `hermes_cli/approvals_suggest.py` first
    /// exists at tag **v2026.7.30** (0.19.1) and is absent from the tree at
    /// v2026.7.20 (0.19.0) — `git ls-tree <tag> -- hermes_cli/approvals_suggest.py`.
    public var hasApprovalsSuggest: Bool { isV0191OrLater }

    /// `hermes cron runs` — list past cron job runs.
    ///
    /// **Floor v0.19.0, not v0.20.** The `runs` subparser is
    /// `hermes_cli/subcommands/cron.py:159` at tag **v2026.7.20**
    /// (`pyproject.toml` = `0.19.0`); the symbol `cron_runs` appears in no
    /// file at v2026.7.7.2 (0.18.2).
    public var hasCronRuns: Bool { isV019OrLater }

    // MARK: v0.18.1 (v2026.7.7) flags — re-floored out of the v0.20 cluster
    //
    // Three flags the v0.20 audit filed under v0.20 whose per-flag tag walks
    // (below) put them at v2026.7.7 = 0.18.1. They stay in this file position
    // rather than moving up to the `v0.18` MARK: the v0.18 section is the
    // 0.18.0 tag (v2026.7.1) and these are one release later, and forty
    // commits of audit docs cite them here. P45 added this header because
    // `hasReasoningDisableAliases` was landing under a MARK reading "v0.20"
    // while its own doc floors it at v0.18.1.

    /// `hermes sessions export --format md|html|qmd|trace` — additional
    /// session export formats beyond the default.
    ///
    /// **Floor v0.18.1, not v0.20.** `hermes_cli/main.py:13546` at tag
    /// **v2026.7.7** (`pyproject.toml` = `0.18.1`) registers
    /// `choices=["jsonl", "md", "qmd", "html", "trace"]` — the exact five;
    /// `qmd` occurs nowhere under `hermes_cli/` at v2026.7.1 (0.18.0). The
    /// option moved to `subcommands/sessions.py:75` by v2026.9.7, unchanged.
    public var hasSessionsExportFormats: Bool { isV0181OrLater }

    /// `max` in `agent.reasoning_effort` / `agent.reasoning_overrides`.
    ///
    /// **Floor v0.18.1, not v0.20.** `VALID_REASONING_EFFORTS` is
    /// `("minimal","low","medium","high","xhigh")` at v2026.7.1 (0.18.0,
    /// `hermes_constants.py:794`) and gains `"max"` in the same line at tag
    /// **v2026.7.7** (`pyproject.toml` = `0.18.1`). Walked across every
    /// `v2026.*` tag; v2026.6.19 and earlier carry the five-level tuple.
    /// Offering the level on a host that accepts it is a permissive
    /// rendering change, not a C1 degradation (round-3 decision 5).
    public var hasReasoningEffortMax: Bool { isV0181OrLater }

    /// The `false` / `disabled` spellings of "reasoning off" in
    /// `agent.reasoning_effort` / `agent.reasoning_overrides` — and, by way
    /// of YAML's bool coercion, bare `off`.
    ///
    /// **Floor v0.18.1, the same tag `max` arrived on — walked, not
    /// assumed.** `parse_reasoning_effort` is typed `(effort: str)` through
    /// **v2026.7.1** (0.18.0, `hermes_constants.py:797-812`) and disables on
    /// `effort == "none"` ALONE (`:809`); `"false"` / `"disabled"` fall past
    /// `VALID_REASONING_EFFORTS` to the closing `return None`, and a YAML
    /// `false` (which is what bare `off` loads as) is caught by the leading
    /// `if not effort` and returns `None` too. At tag **v2026.7.7** (0.18.1)
    /// the signature widens to `(effort)`, the body gains
    /// `str(effort).strip().lower()` and the alias set becomes
    /// `{"none", "false", "disabled"}` (`:816`) — byte-identical at every
    /// tag from there to `v2026.9.7` (`:885`).
    ///
    /// So below this floor those three spellings do NOT disable reasoning:
    /// the host logs `Unknown reasoning_effort` and uses its own default.
    /// That is exactly the difference
    /// ``HermesReasoningEffort/unsupportedLevelNotice(for:capabilities:)``
    /// renders.
    public var hasReasoningDisableAliases: Bool { isV0181OrLater }

    // MARK: v0.19.0 (v2026.7.20) flags — re-floored out of the v0.20 cluster

    /// `ultra` in `agent.reasoning_effort` / `agent.reasoning_overrides`.
    ///
    /// **Floor v0.19.0, not v0.20.** `VALID_REASONING_EFFORTS` still ends at
    /// `"max"` at v2026.7.7.2 (0.18.2, `hermes_constants.py:794`) and gains
    /// `"ultra"` at tag **v2026.7.20** (`pyproject.toml` = `0.19.0`,
    /// `hermes_constants.py:835-837`), where the tuple wraps to two lines.
    /// One release later than ``hasReasoningEffortMax`` — the two levels did
    /// not arrive together.
    public var hasReasoningEffortUltra: Bool { isV019OrLater }

    // MARK: v0.19.x re-floored flags (v2026.7.20 = 0.19.0, v2026.7.30 = 0.19.1)
    //
    // These shipped in the v0.20 audit's flag cluster because v2026.7.30 was
    // read as an unnumbered pre-release. It is not — `pyproject.toml:5` at
    // that tag reads `version = "0.19.1"` — so each floor below is the tag
    // the surface actually landed in, and 0.19.x hosts get the surfaces they
    // genuinely have. Each doc comment carries the verified file:line.

    /// `approvals.smart_policy` — operator-customizable free-text policy
    /// appended to the smart-approval guardian's system prompt
    /// (hermes-agent commit bd1db5460a "feat(approvals): operator-
    /// customizable smart-approval policy", first released v2026.7.30).
    ///
    /// **Floor v0.19.1, not v0.20.** v2026.7.30 is not an unnumbered
    /// pre-release: its `pyproject.toml:5` reads `version = "0.19.1"`
    /// (v2026.7.20 = 0.19.0, v2026.8.3 = 0.20.0). Verified present at that
    /// tag: `hermes_cli/config_defaults.py:1945` `"smart_policy": ""`,
    /// inside the `"approvals"` block opened at `:1935`.
    public var hasApprovalSmartPolicy: Bool { isV0191OrLater }

    /// `secrets.bitwarden.encrypted_cache.{enabled,max_stale_seconds}` —
    /// optional encrypted last-good Bitwarden fallback for network/timeout
    /// outages (hermes-agent commit 1384087729 "fix(secrets): add
    /// encrypted Bitwarden stale cache", first released v2026.7.30 = 0.19.1
    /// per that tag's `pyproject.toml:5`). Verified at v2026.7.30:
    /// `hermes_cli/config_defaults.py:2792` `"encrypted_cache": {`, `:2793`
    /// `"enabled": False,`, `:2794` `"max_stale_seconds": 0,`.
    public var hasBitwardenEncryptedCache: Bool { isV0191OrLater }

    /// `secrets.command.*` — any-CLI vault helper secret source
    /// (hermes-agent commit 3d5dd8efa5 "feat(secrets): add `command` secret
    /// source", first released v2026.7.30 = 0.19.1 per that tag's
    /// `pyproject.toml:5`). These keys are NOT in `config_defaults.py` on
    /// any tag — the source declares its own schema and reads the block
    /// itself. Verified at v2026.7.30: `agent/secret_sources/command.py:416`
    /// `"enabled": {"description": "Master switch", "default": False}`,
    /// `:436` `command = str(cfg.get("command") or "").strip()`, registered
    /// at `agent/secret_sources/registry.py:179-181`.
    public var hasCommandSecretSource: Bool { isV0191OrLater }

    /// `telemetry.shared_metrics.enabled` — privacy-safe opt-in aggregate
    /// metrics written only to this profile's local telemetry directory,
    /// no remote sink (Relay pipeline commits 3bd338d2a9,
    /// 64faff6768, 056e7df0e0, 9baa8cc96c, 36185bf2e2, 43d994986e,
    /// 841a5a744a/14bed44c8c revert+reapply, all first released
    /// v2026.7.30).
    ///
    /// "No remote sink" was true through v0.21.0 and is NOT true from
    /// v0.21.1, which adds the `send`/`endpoint` transmission keys — see
    /// `hasSharedMetricsSend`. This flag stays about the local COLLECTION
    /// switch (`telemetry.shared_metrics.enabled`), which is unchanged.
    ///
    /// Floor v0.19.1: v2026.7.30's `pyproject.toml:5` reads
    /// `version = "0.19.1"`, and that tag's
    /// `hermes_cli/config_defaults.py:2627` opens `"telemetry": {`, `:2628`
    /// `"shared_metrics": {`, `:2629` `"enabled": False,`.
    public var hasSharedMetricsTelemetry: Bool { isV0191OrLater }

    /// `database.{journal_mode,wal_autocheckpoint,journal_size_limit}` —
    /// SQLite journal mode + WAL sizing pragmas applied by every Hermes
    /// database opener (`journal_mode` via commit 91351b7b7
    /// "fix(state): make journal mode canonical and behaviorally
    /// verified", `wal_autocheckpoint`/`journal_size_limit` via commit
    /// 9d4bfd5e3 "fix(config): register WAL sizing pragmas in
    /// DEFAULT_CONFIG" — both first released v2026.7.30 = 0.19.1 per that
    /// tag's `pyproject.toml:5`). Verified at v2026.7.30:
    /// `hermes_cli/config_defaults.py:16` `"database": {`, `:17`
    /// `"journal_mode": "wal",`, `:20` `"wal_autocheckpoint": None,`,
    /// `:21` `"journal_size_limit": None,`.
    public var hasDatabaseJournalSettings: Bool { isV0191OrLater }

    /// `stt.language` (global fallback hint, default `"en"`) +
    /// `stt.groq.{model,language}` — the unified STT language resolver
    /// (hermes-agent commit a10bd49ddd "feat(stt): unify language
    /// resolution across all STT providers" + commit bc997a36a8 "feat(stt):
    /// default global stt.language to 'en'", both first released
    /// v2026.7.30). Groq's STT provider itself predates this (env-var
    /// only); the commit is what makes `stt.groq.model`/`stt.groq.language`
    /// config-driven.
    ///
    /// **Floor v0.19.1, not v0.20** — v2026.7.30's `pyproject.toml:5` reads
    /// `version = "0.19.1"`, a numbered release, so the surface is
    /// guaranteed at v0.19.1. Verified at that tag:
    /// `hermes_cli/config_defaults.py:1420` `"language": "en",` under
    /// `"stt": {` (`:1408`), and `:1432-1435` the `"groq": {` block with
    /// `"model": "whisper-large-v3-turbo"` / `"language": ""`.
    public var hasSTTUnifiedLanguage: Bool { isV0191OrLater }

    /// `stt.local.{vad,vad_min_silence_ms,no_speech_prob_threshold,
    /// logprob_threshold}` — faster-whisper anti-hallucination tuning
    /// (hermes-agent commit bf8004e3a8 "fix(stt): kill faster-whisper
    /// silence hallucinations at the source", first released v2026.7.30 =
    /// 0.19.1 — same tag as `hasSTTUnifiedLanguage`, same floor). Verified
    /// at v2026.7.30: `hermes_cli/config_defaults.py:1427` `"vad": True,`,
    /// `:1428` `"vad_min_silence_ms": 500,`, `:1429`
    /// `"no_speech_prob_threshold": 0.6,`, `:1430`
    /// `"logprob_threshold": -1.0,`.
    public var hasSTTLocalVADTuning: Bool { isV0191OrLater }

    /// `provider_override` in the `kanban list --json` task envelope.
    ///
    /// **Floor v0.19.1 (`v2026.7.30`), not v0.21.1.** P42 read the FILE move
    /// for the KEY's birth: the task dict moved out of
    /// `hermes_cli/kanban.py::_task_to_dict` into
    /// `hermes_cli/kanban_output.py::_TASK_DICT_FIELDS` at `v2026.9.7`, and
    /// grepping the new file across the tags found only the new tag. The key
    /// itself is two releases older. Re-walked by opening
    /// `hermes_cli/kanban.py` at every `v2026.*` tag: `_task_to_dict` gains
    /// `"provider_override": t.provider_override` at **`v2026.7.30`**
    /// (`:80`; `pyproject.toml` = `0.19.1`) and has it at every later tag
    /// including `v2026.8.31` (`:80`); `v2026.7.20` (0.19.0) has no
    /// occurrence of the name in the file at all. `list --json` prints
    /// `[_task_to_dict(t) for t in tasks]` at `v2026.7.30:1594`, so that tag
    /// is the first that EMITS it, not merely the first that stores it.
    ///
    /// Gates the inspector's `Provider:` chip only; the DECODE is
    /// `decodeIfPresent` and stays ungated (C1).
    public var hasKanbanProviderOverride: Bool { isV0191OrLater }

    /// `gateway.profile_routes` (and the top-level `profile_routes` form) —
    /// per-guild/channel/thread routing of inbound gateway messages to
    /// distinct Hermes profiles (hermes-agent commit 5e65f6d79f
    /// "feat(gateway): add profile-based routing for inbound messages",
    /// 2026-06-27). Unlike most of the v0.20 surface this one is genuinely
    /// older: the first tag containing it is v2026.7.20, whose
    /// `pyproject.toml` reads `version = "0.19.0"` (the preceding tag
    /// v2026.7.7.2 was 0.18.2), so the true floor is **v0.19**, not v0.20.
    public var hasGatewayProfileRoutes: Bool { isV019OrLater }

    /// The spelling of ACP's "compress conversation context" slash command:
    /// `true` means `/compress`, `false` means `/compact`.
    ///
    /// **This gates the ACP adapter, not the CLI/TUI command table.** Scarf's
    /// chat composer speaks ACP, whose slash set is its own smaller dict —
    /// `hermes_cli/commands.py`, where `compress` has been canonical since
    /// v2026.3.17 (0.3.0), is a different table and says nothing about what
    /// the composer may send. Walked across all 32 `v2026.*` tags:
    ///
    /// * `_SLASH_COMMANDS` carries `"compact": "Compress conversation
    ///   context"` from v2026.3.17 (0.3.0) through **v2026.7.20 (0.19.0)**
    ///   (`acp_adapter/server.py:459` @ v2026.7.20, handler registered at
    ///   `:1759`).
    /// * It flips to `"compress"` at **v2026.7.30 (0.19.1)**
    ///   (`acp_adapter/server.py:574`, `:603`, handler `:2051`) and stays
    ///   there through v2026.9.7, where the set moved to
    ///   `acp_adapter/commands.py:54`.
    ///
    /// **There is no alias in either direction.** `_handle_slash_command` is
    /// `if cmd not in self._COMMANDS: return None`, and its own docstring says
    /// unknown commands "fall through to the LLM" (`acp_adapter/commands.py:88-95`
    /// @ v2026.9.7; same shape at `acp_adapter/server.py:1743-1748` @
    /// v2026.7.20). So the wrong spelling does not error — it silently burns a
    /// turn prompting the model with the literal text, and nothing compresses.
    ///
    /// That makes this a real gate on the LARGER half of the window: 0.6.0
    /// through 0.19.0 is thirteen of the sixteen supported releases, and on
    /// those hosts `/compact` is the only spelling that works. On a v0.12 host
    /// `/compress` is not even a display-mode toggle — the TUI's `/compact`
    /// entry (`tui_gateway/server.py:3846` `_TUI_EXTRA` at v2026.4.30) is a
    /// different surface again, and the ACP adapter is the one Scarf drives.
    ///
    /// An undetected host (`.empty`) resolves to `/compact`, the pre-0.19.1
    /// spelling, per C1: a host Scarf cannot version must behave as the older
    /// one.
    public var hasACPCompressSpelling: Bool { isV0191OrLater }

    // MARK: v0.20 (v2026.8.3) flags — continued

    // MARK: v0.20.3 (v2026.8.16.2) flags

    /// Bot Mode's storage format: a profile is a bot when its `profile.yaml`
    /// carries a `ui_meta['hermes-bots']` **mapping**, with the avatar in
    /// `<profile_dir>/assets/avatar.{png,jpg,webp}`.
    ///
    /// **The floor is v0.20.3, not v0.21** — this is the correction the v0.21
    /// audit's "gate Bot Mode on `isV021OrLater`" line needed once the tags
    /// were walked (charter C2: a finding is real only when cited against the
    /// tagged source). Two independent pieces landed separately:
    /// - `ui_meta` persistence in `profile.yaml` + `profiles.set_asset` /
    ///   `get_asset` first appear in `tui_gateway/methods_profiles.py` at tag
    ///   v2026.8.13 (`pyproject.toml` version `0.20.1`).
    /// - The `hermes-bots` convention itself — `tools/bot_mode_probe.py`, with
    ///   `_is_bot_managed` reading `ui_meta['hermes-bots']` and the canonical
    ///   "Bot Chat" title — first appears at tag **v2026.8.16.2**
    ///   (`version = "0.20.3"`). Verified with
    ///   `git ls-tree <tag> -- tools/bot_mode_probe.py` across every tag from
    ///   v2026.8.3 onward: absent through v2026.8.16, present from
    ///   v2026.8.16.2.
    ///
    /// What v0.21 actually added is the *compare-and-swap* layer
    /// (`_ui_meta_revisions`, `ui_meta_expected_revisions`), which arrived at
    /// v2026.8.19 (0.20.5) and which Scarf does not use — it edits
    /// `profile.yaml` directly, since no `hermes profile` verb touches
    /// `ui_meta`. So gating the roster on `isV021OrLater` would hide a working
    /// surface from three releases of hosts that support it.
    ///
    /// **Version-only, deliberately not version-plus-data.** Bot Mode is inert
    /// on a host where no profile is bot-managed, which is tempting to fold
    /// into the gate — but a data gate makes the feature unbootstrappable: no
    /// bots means no Bots section means no way to create the first bot. The
    /// flag answers "can this host store a bot"; the empty roster is an empty
    /// *state*, not a hidden feature. (Contrast `hasCronIncidents`, where the
    /// gated thing is a CLI verb that either exists or errors.)
    public var hasBotMode: Bool { isV0203OrLater }

    // MARK: v0.20.4 (v2026.8.18) flags
    //
    // Group name kept for continuity with the v0.20.4 audit that created it;
    // the re-floor walk moved EVERY member DOWN a patch or three — each
    // flag's own doc comment carries its verified tag, and since P55 re-floored
    // `hasMCPIdentityHeader` to v0.20.1 no member of this group still has a
    // v0.20.4 floor. The MARK is a location, never evidence.

    /// `is_job_runnable()` now blocks a cron job from firing whenever
    /// `state == "paused"` or `paused_at` is set, regardless of `enabled`
    /// (v0.20.4+; at v2026.9.7 `cron/jobs.py:482-485` `is_job_runnable`
    /// returns `bool(job.get("enabled", True)) and not _has_pause_marker(job)`,
    /// with `_has_pause_marker` at `:477` and the claim gate at `:2509`
    /// `if not force and not is_job_runnable(job)`). Scarf's
    /// `withEnabled(true)` must also force `state = "scheduled"` and strip
    /// `paused_at`/`paused_reason`, not just flip `enabled`, or a
    /// re-enabled job silently never runs again. This is a patch-level
    /// floor — v0.20.0 hosts still forward the old enabled-only semantics,
    /// so `isV020OrLater` would light this up too early.
    ///
    /// **Floor v0.20.1, not v0.20.4.** `_has_pause_marker` is
    /// `cron/jobs.py:482` at tag **v2026.8.13** (`pyproject.toml` =
    /// `0.20.1`), with `is_job_runnable` calling it at `:498`; the symbol
    /// occurs nowhere in `cron/jobs.py` at v2026.8.3 (0.20.0).
    ///
    /// **No consumer yet** — `HermesCronJob.withEnabled` clears the pause
    /// markers UNCONDITIONALLY (see its own doc comment for why that is safe
    /// on a pre-0.20.1 host), so nothing reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasCronPauseMarkerGate: Bool { isV0201OrLater }

    /// The two ways a task leaves the Kanban **Review** column from Scarf:
    /// `review -> done` via `hermes kanban complete`, and `review ->
    /// ready|todo` via `hermes kanban reopen-review` (v0.20.1+).
    ///
    /// **Floor walked both ways, and it is NOT `hasKanbanV015`.** Round-6
    /// decision 6 named that flag; the source says otherwise, so C2 wins.
    /// `complete_task`'s UPDATE reads
    /// `AND status IN ('running', 'ready', 'blocked')` at **v2026.8.3**
    /// (`pyproject.toml` = `0.20.0`, `hermes_cli/kanban_db.py` — the clause
    /// appears twice, once per `expected_run_id` arm) and
    /// `AND status IN ('running', 'ready', 'blocked', 'review')` at
    /// **v2026.8.13** (`0.20.1`). At the v0.15 floor `v2026.5.28` the clause
    /// is the three-status form, so gating on `hasKanbanV015` would have
    /// offered a drag that `complete_task` returns `False` for — `kanban
    /// complete` then prints `cannot complete <id> (unknown id or terminal
    /// state)` and exits 1 (`hermes_cli/kanban_output.py:61-69`
    /// `_bulk_apply`), i.e. a card that springs back with a refusal, on five
    /// releases' worth of hosts.
    ///
    /// `reopen-review` lands at the SAME tag — `reopen-review` /
    /// `reopen_review` occur zero times under `hermes_cli/` at every tag
    /// through `v2026.8.3` and twice from `v2026.8.13` on — so one flag
    /// covers both doors rather than two flags that would always agree. At
    /// `v2026.9.7` the verb is `hermes_cli/kanban_parser.py:323-326`
    /// (`task_ids` `nargs="+"` plus a plain `--reason`), dispatched at
    /// `hermes_cli/kanban.py:1243` to `_cmd_reopen_review` (`:990-1008`),
    /// which calls `reopen_review_task` (`kanban_db.py:3295-3328`):
    /// `UPDATE tasks SET status = ? … WHERE id = ? AND status = 'review'`,
    /// where the new status is `_landing_status_after_parents` — `ready` or
    /// `todo`, both of which Scarf's board collapses into **Up Next**.
    ///
    /// **C1 for an added gate.** This gates a surface that did not exist:
    /// before P56 every drag out of Review threw "No CLI path exists for
    /// this transition." on EVERY host. Below the floor that refusal is
    /// unchanged, so no range renders differently from the last release;
    /// above it, two refusals become two working verbs.
    public var hasKanbanReviewExits: Bool { isV0201OrLater }

    /// The 14 inline built-in personalities were removed from
    /// `config.yaml`'s `agent.personalities` block; canon moved to
    /// `hermes_cli/personality.py:17` `BUILTIN_PERSONALITIES` in code
    /// (v0.20.4+). Scarf's personality pickers must hardcode/union the
    /// built-in list instead of relying solely on the YAML scrape.
    ///
    /// **Floor v0.20.1, not v0.20.4.** `hermes_cli/personality.py` first
    /// exists at tag **v2026.8.13** (`pyproject.toml` = `0.20.1`) and is
    /// absent from the tree at v2026.8.3 (0.20.0) — `git ls-tree <tag> --
    /// hermes_cli/personality.py`. The v0.20.4 floor withheld the built-in
    /// union from every 0.20.1–0.20.3 host that already had it.
    public var hasBuiltinPersonalitiesInCode: Bool { isV0201OrLater }

    /// `hermes curator ledger [--skill N]` — list the curator's ledger of
    /// managed entries.
    ///
    /// **Floor v0.20.3, not v0.20.4** (`hermes_cli/curator.py:996` at tag
    /// **v2026.8.16.2**, `pyproject.toml` = `0.20.3`; `ledger` occurs
    /// nowhere in that file at v2026.8.16 = 0.20.2).
    public var hasCuratorLedger: Bool { isV0203OrLater }

    /// `hermes curator purge [--days] [-y]` — permanently delete archived
    /// curator entries, distinct from `prune` (archive-only).
    ///
    /// **Floor v0.20.3, not v0.20.4** (`hermes_cli/curator.py:1011` at tag
    /// **v2026.8.16.2** = 0.20.3; `purge` occurs nowhere in that file at
    /// v2026.8.16 = 0.20.2).
    public var hasCuratorPurge: Bool { isV0203OrLater }

    /// `hermes curator rollback <entry_id>` — revert a single curator
    /// ledger entry.
    ///
    /// **Floor v0.20.3, not v0.20.4** (`hermes_cli/curator.py:972` at tag
    /// **v2026.8.16.2** = 0.20.3; v2026.8.16 = 0.20.2 has `rollback` only in
    /// prose, with no subparser).
    public var hasCuratorEntryRollback: Bool { isV0203OrLater }

    /// `hermes skills trust/untrust` + repo-local project skills under
    /// `./.hermes/skills`. Scarf's `SkillsScanner` only scans
    /// `~/.hermes/skills` today — this is the largest functional gap on
    /// the skills surface.
    ///
    /// **Floor v0.20.3, not v0.20.4** (`hermes_cli/subcommands/skills.py:22`
    /// `"trust"` and `:33` `"untrust"` at tag **v2026.8.16.2** = 0.20.3;
    /// neither verb is registered in that file at v2026.8.16 = 0.20.2).
    public var hasSkillsProjectTrust: Bool { isV0203OrLater }

    /// `hermes skills update --force` — override the "kept your local
    /// edits" skip and force-overwrite a locally-edited skill.
    /// Do not wire this up as the default; it discards user edits.
    ///
    /// **Floor v0.20.3, not v0.20.4**: `skills_update.add_argument("--force",
    /// …, help="Overwrite skills you have edited locally …")` is
    /// `hermes_cli/subcommands/skills.py:164` at tag **v2026.8.16.2** =
    /// 0.20.3. At v2026.8.16 = 0.20.2 that file's only `--force` arguments
    /// are `install`'s (`:102`) and the hub-install one (`:299`); `update`
    /// has none.
    public var hasSkillsUpdateForce: Bool { isV0203OrLater }

    /// Per-MCP-server `identity_header` (plus `strict_redirect_headers`
    /// and stdio `cwd`) in the MCP catalog config.
    ///
    /// **Floor v0.20.1, not v0.20.4** (P55 re-walk; charter C2). Both blobs
    /// opened:
    ///
    /// - **`v2026.8.3`** (`pyproject.toml` = **0.20.0**): `tools/mcp_tool.py`
    ///   contains `identity_header` zero times, `strict_redirect_headers`
    ///   zero times, and no `cwd=config.get("cwd")`.
    /// - **`v2026.8.13`** (**0.20.1**): all three arrive together —
    ///   `identity_header` documented in the module header at `:40` with
    ///   `_resolve_identity_header` at `:1335` and `_apply_identity_header`
    ///   at `:1389`; `strict_redirect_headers` read at `:3035`; the stdio
    ///   server's `cwd=config.get("cwd")` at `:2705`.
    ///
    /// **What each version range renders differently than Scarf's last
    /// release** (charter C1): only **0.20.1 – 0.20.3** changes. The single
    /// consumer — `MCPServerEditorView.swift:67`'s identity-header section —
    /// now appears on those hosts, which do honour all three keys, instead
    /// of being hidden as if they did not. Below 0.20.1 and at 0.20.4+ the
    /// rendering is identical to the last release.
    public var hasMCPIdentityHeader: Bool { isV0201OrLater }

    // MARK: v0.20.5 (v2026.8.19) flags

    /// `get_managed_system()` READS the `.managed` marker file's contents and
    /// honours `_IGNORED_MANAGED_VALUES` there (v0.20.5+).
    ///
    /// Below this floor the marker is a pure existence check: every tag from
    /// v2026.3.12 through **v2026.8.18** ends `get_managed_system` with
    /// ```
    /// managed_marker = get_hermes_home() / ".managed"
    /// if managed_marker.exists():
    ///     return "NixOS"
    /// ```
    /// (`hermes_cli/config.py:327-330` @ v2026.6.19; byte-identical at
    /// v2026.7.20 and at v2026.7.30, where `_IGNORED_MANAGED_VALUES` FIRST
    /// appears but applies only to the `HERMES_MANAGED` env var, never to the
    /// marker). The contents-reading form — `read_text(...)`, the `OSError`
    /// → `""` arm, and the ignored-values check on the marker — arrives at
    /// **v2026.8.19 = 0.20.5**, walked tag by tag over both file locations.
    ///
    /// So on a pre-v0.20.5 host a `.managed` file holding `brew` means
    /// **managed** (system `"NixOS"`, that tag's literal spelling), while on
    /// v0.20.5+ it means not managed at all. Scarf's probe has to branch, or
    /// it locks a Homebrew install out of its own Settings on a new host — or
    /// leaves a genuinely managed old host writable. See
    /// ``HermesManagedInstall/system(fromMarker:readsMarkerContents:)``.
    public var hasManagedMarkerContents: Bool { isV0205OrLater }

    /// The bare `hermes version` subcommand was removed (dropped from
    /// `_BUILTIN_SUBCOMMANDS`, `hermes_cli/main.py:2595` — no `"version"`
    /// entry in the frozenset at v2026.9.7; `subcommands/version.py`
    /// deleted) and `hermes --version` (`hermes_cli/_parser.py:112`
    /// `add("--version", "-V", action="store_true", ...)`) now carries the
    /// full output including the `commits behind` line (`banner.py:267`)
    /// (v0.20.5+). Pre-v0.20.5 hosts print only the short banner from
    /// `--version` and need the `version` subcommand for update status, so
    /// argv selection must branch on this flag: on a v0.20.5 host `version`
    /// falls through to plugin discovery and burns an agent turn.
    public var hasVersionFlagFullOutput: Bool { isV0205OrLater }

    /// `hermes cron create/edit --reasoning-effort <level>` — per-job
    /// thinking-level override persisted as `reasoning_effort` in
    /// `jobs.json` (v0.20.5+; at v2026.9.7 the argparse blocks are
    /// `hermes_cli/subcommands/cron.py:72` for `cron create` and `:135` for
    /// `cron edit` — the v0.21.1 modularization moved them out of main.py).
    /// There is NO `cron --reasoning-effort` at the `cron` parser level;
    /// only the two subverbs take it.
    /// Older hosts reject the unknown argument outright — argparse fails the
    /// whole `cron create` — so every cron-write path must gate on this.
    ///
    /// **No consumer yet** — no Scarf cron-write path passes
    /// `--reasoning-effort`, so nothing reads this flag today.
    public var hasCronReasoningEffort: Bool { isV0205OrLater }

    // Moved here from the v0.21 MARK group by round-6 P59: the floor is
    // v0.20.5 and a v0.20.5 group exists, so the declaration now sits with the
    // flags its group tests cover — and it is enumerated in all four of them.
    // (Where no group matches a re-floored flag — `hasMCPIdentityHeader` and
    // `hasKanbanReviewExits`, both v0.20.1 — P55 and P56b kept it in place and
    // said so in the MARK: the MARK is a location, never evidence. Here the
    // right location already existed, so the note is not needed twice.)

    /// The full argv Scarf needs to CREATE a bot's canonical Bot Chat:
    /// `hermes -p <bot> chat --in ~ -c "Bot Chat" --create-if-missing -Q
    /// --query-file <path>` (see
    /// `BotConversationViewModel.createCanonicalBotChat`).
    ///
    /// **Source-verified per flag, at the `hasBotMode` floor tag
    /// v2026.8.16.2 (0.20.3) and at v2026.8.31 (0.21.0):**
    /// - `-c/--continue` — present at 0.20.3 (`hermes_cli/_parser.py:401`).
    /// - `--create-if-missing` — present at 0.20.3 (`_parser.py:410`).
    /// - `-Q/--quiet` — present at 0.20.3 (`_parser.py:368`).
    /// - `--in` — present at 0.20.3 (`_parser.py:390`).
    /// - **`--query-file` — ABSENT at 0.20.3.** `git grep query-file
    ///   v2026.8.16.2 -- '*.py'` returns nothing; the chat parser there has
    ///   only `-q/--query` (`_parser.py:304`).
    ///
    /// argparse rejects the WHOLE invocation on an unknown flag, so below
    /// the floor the create would fail with a parser error rather than doing
    /// anything. The creation path is therefore floored at the tag where
    /// every flag exists, and the pane says so instead of offering a button
    /// that cannot work. Reading and messaging an EXISTING Bot Chat goes over
    /// ACP and stays on the `hasBotMode` floor.
    ///
    /// `--query-file` is not substitutable with `-q <text>` here: the body is
    /// arbitrary user text that would ride a remote `bash -lc` command line.
    ///
    /// **That tag is v0.20.5, not v0.21** (P55 re-walk; charter C2 — the
    /// "first appears at v0.21" line above was the un-walked half of an
    /// otherwise per-flag-verified doc). Both blobs opened:
    ///
    /// - **`v2026.8.18`** (`pyproject.toml` = **0.20.4**):
    ///   `hermes_cli/_parser.py` contains neither `--query-file` nor
    ///   `query_file`.
    /// - **`v2026.8.19`** (**0.20.5**): the chat parser's mutually-exclusive
    ///   query group is `hermes_cli/_parser.py:303-316` (opened at `:303`,
    ///   closed at `:316`). Both members are cited on their
    ///   `add_argument(` line: `-q`/`--query` at `:304` and `--query-file`
    ///   at `:307`. Every other flag of the argv is present at that same
    ///   tag: `--in` `:401`, `--continue`/`-c` `:411-412`,
    ///   `--create-if-missing` `:421`, `-Q`/`--quiet` `:379-380`.
    ///   `--profile`/`-p` is **not a parser argument at all**: `main.
    ///   _apply_profile_override` consumes it before argparse runs, and
    ///   `_parser.py:20-23` is only the `PRE_ARGPARSE_INHERITED_FLAGS`
    ///   table that records it for relaunch (`:16-19` says so).
    ///
    /// **What each version range renders differently than Scarf's last
    /// release** (charter C1): only **0.20.5 and 0.20.6** change. The single
    /// consumer — `BotConversationView.swift:27`'s create affordance — now
    /// offers the button on hosts whose parser accepts every flag of the
    /// argv, instead of showing the unsupported note. Below 0.20.5 (where
    /// the argv would die on an unknown flag) and at 0.21+ the rendering is
    /// identical to the last release.
    public var hasBotChatCreationCLI: Bool { isV0205OrLater }

    // MARK: v0.21 (v2026.8.31) flags
    //
    // v0.21 ("Pantheon") is an additive cycle. Note the intermediate
    // v0.20.6 tag (v2026.8.27) sitting between v0.20.5 and v0.21.0: four
    // of the surfaces the v0.21 release notes advertise actually landed
    // there, so they carry the patch-level `isV0206OrLater` floor rather
    // than `isV021OrLater` — gating them at v0.21 would needlessly hide
    // working UI from v0.20.6 hosts. Same precedent as
    // `hasGatewayProfileRoutes` living in the v0.20 group on a v0.19 floor.

    /// `hermes peer run` / `peer status` / `peer stop` — start a long peer
    /// turn asynchronously (with an `--idempotency-key`), poll its status
    /// and final output, and stop one run without touching another
    /// (v0.21+, `hermes_cli/subcommands/peer.py:432-434` — the three
    /// `_remote("run"/"status"/"stop", ...)` registrations, dispatched at
    /// `:361`). Verified absent
    /// at both v2026.8.19 (0.20.5) and v2026.8.27 (0.20.6), whose `peer`
    /// subparser stops at `add`/`list`/`remove`/`dm` — so older hosts fail
    /// argparse outright on these verbs.
    public var hasPeerRunCommands: Bool { isV021OrLater }

    /// `hermes cron doctor` — check scheduled jobs for common health
    /// issues (v0.21+, `hermes_cli/subcommands/cron.py:184`
    /// `cron_subparsers.add_parser("doctor", ...)`). Unlike its
    /// `cron incidents` sibling this one is genuinely new at v0.21:
    /// verified absent from cron.py at v2026.8.27 (0.20.6).
    public var hasCronDoctor: Bool { isV021OrLater }

    /// `hermes config set` interprets a backslash-escaped dot (`\.`) inside
    /// a key segment as a literal dot rather than a nesting separator, and
    /// hard-errors on phantom siblings (v0.21+, hermes-agent commit
    /// a42aee9585 "fix(config): greedy literal-key matching + loud
    /// phantom-sibling refusal for dotted key names", contained only in
    /// v2026.8.31). This is what lets Scarf write keys whose own name
    /// contains a dot — `quick_commands.v1\.2_deploy.type`,
    /// `providers.qwen3\.5-397b.api_key`. Pre-v0.21 hosts silently split
    /// such a key into nested maps and corrupt the config, so escaping must
    /// be gated on this rather than applied unconditionally.
    public var hasConfigDottedKeyEscape: Bool { isV021OrLater }

    /// `hermes cron incidents [list|ack]` — durable cron failure incidents
    /// backed by a `cron_incidents` table in `cron/executions.db`
    /// (`hermes_cli/subcommands/cron.py:165-166`
    /// `cron_incidents = cron_subparsers.add_parser("incidents", ...)`,
    /// `--state` at `:167`). Advertised with v0.21
    /// but present already at v2026.8.27 (0.20.6), hence the patch floor.
    public var hasCronIncidents: Bool { isV0206OrLater }

    /// `hermes cron resume --run-now` / `--at <ISO-8601>` — re-arm a paused
    /// job to fire immediately or at a chosen time, i.e. "Trigger now"
    /// (`hermes_cli/subcommands/cron.py:146` `--at` / `:147` `--run-now`).
    /// Absent at v2026.8.19 (0.20.5) — where `cron
    /// resume` takes a bare `job_id` and argparse rejects the flags — but
    /// present at v2026.8.27 (0.20.6), so the floor is v0.20.6.
    public var hasCronResumeRunNow: Bool { isV0206OrLater }

    /// Whether `hermes cron resume <id>` recovers a RECURRING job stuck in
    /// `state = "error"`.
    ///
    /// The terminal-activation guard gained its `and not
    /// _is_recoverable_error_job(job)` arm at `v2026.8.31`
    /// (`pyproject.toml version = "0.21.0"`). **Do not grep for
    /// `_reject_terminal_activation` at that tag** — the helper does not
    /// exist there: v2026.8.31 still carries the guard as two INLINE blocks
    /// inside `update_job`'s `apply` (`cron/jobs.py:2583-2595` and
    /// `:2684-2696`), and only `v2026.9.7` extracts it into the named
    /// function at `:1865-1879` (called from `:1941` / `:1965`).
    /// The predicate itself is defined at `v2026.8.31:664-692` and
    /// is absent from every earlier tag. At `v2026.8.27` (0.20.6) the same
    /// block reads `is_terminal_job(job) and (…)` with no exemption
    /// (`:2270-2278`, `:2367-2375`), so a resume of an error-state cron or
    /// interval job raises "Cannot activate terminal cron job …" and
    /// `cron_resume` returns 1.
    ///
    /// A walk of all 32 `v2026.*` tags for `_is_recoverable_error_job`
    /// matches exactly `v2026.8.31` and `v2026.9.7` — first tag with it
    /// `v2026.8.31` (0.21.0), last tag without it `v2026.8.27` (0.20.6).
    /// Minor-level floor, so a v0.21.0 host gets it too.
    public var hasCronRecoverableErrorResume: Bool { isV021OrLater }

    /// Whether `resume_job` refuses a one-shot whose `run_at` is already past
    /// the grace window, instead of writing an `enabled` record that can never
    /// fire.
    ///
    /// `resume_job` raises `"Cannot resume: one-shot time {run_at} is in the
    /// past (grace window: {ONESHOT_GRACE_SECONDS}s) and will never fire."`
    /// (`cron/jobs.py:1991-1996` @ `v2026.9.7`). Walked across all 32
    /// `v2026.*` tags: first tag with that sentence is **`v2026.7.7`**
    /// (`pyproject.toml` = `0.18.1`), last tag without it is `v2026.7.1`
    /// (0.18.0). Below the floor the host happily resumes such a job, so
    /// Scarf must not pre-refuse it (charter C1) — `recoveryOffer` takes this
    /// as `hostRefusesPastOneShotResume`.
    public var hasCronPastOneShotResumeRefusal: Bool { isV0181OrLater }

    /// `hermes cron create/edit --deliver bot-chat[:profile]` — inject a
    /// job's output into a local profile's canonical Bot Chat session as a
    /// message the bot then responds to (`hermes_cli/subcommands/cron.py:29`
    /// — the `cron create --deliver` help text lists `bot-chat[:profile]`;
    /// `cron edit --deliver` at `:93`). Like
    /// `--deliver all` before it (see `supportsCronDeliver(_:)`), an
    /// unsupported `--deliver` value makes argparse reject the whole
    /// `cron create`. Absent at v2026.8.19, present at v2026.8.27.
    public var hasCronBotChatDelivery: Bool { isV0206OrLater }

    /// `hermes browser close-profile` and the rest of the new top-level
    /// `browser` subcommand (registered in `_BUILTIN_SUBCOMMANDS` at
    /// `hermes_cli/main.py:2595` — `"browser"` is the 16th entry of that
    /// frozenset at v2026.9.7; the parser itself at
    /// `hermes_cli/subcommands/browser.py:10`, with `close-profile` at
    /// `:18-19`).
    /// Destructive — it terminates the browser process tree holding the
    /// user's real profile — so any Scarf affordance must be
    /// confirmation-gated on top of this version gate. Absent at
    /// v2026.8.19, present at v2026.8.27, so the floor is v0.20.6.
    ///
    /// **No consumer yet** — nothing in Scarf reads this flag. Kept because the
    /// floor is source-verified and rediscovering it costs a tag walk.
    public var hasBrowserCloseProfile: Bool { isV0206OrLater }

    /// Whether the `auxiliary.web_extract.*` config block still exists on the
    /// host. **Inverse semantics** — `true` means the Auxiliary tab's "Web
    /// Extract" row should still be shown.
    ///
    /// `web_extract` stopped using an auxiliary LLM upstream: pages are now
    /// truncate-and-stored behind a `read_file` pointer, and the whole block
    /// was deleted from `hermes_cli/config_defaults.py`, which now carries an
    /// explicit tombstone comment ("The old ``auxiliary.web_extract.*`` block
    /// was removed here. Existing values in user config.yaml files are
    /// harmless leftovers and ignored."). Despite being advertised with
    /// v0.21, the deletion actually landed at v2026.8.27 (0.20.6) — the block
    /// is still present at v2026.8.19 (0.20.5) — so the floor is v0.20.6.
    ///
    /// Same shape as `hasFlushMemoriesAux`, and the same unknown-version
    /// policy: an unparseable version hides the row rather than offering a
    /// control that writes a key the host may ignore.
    public var hasWebExtractAux: Bool {
        guard let s = semver else { return false }        // unknown → hide
        return s < SemVer(major: 0, minor: 20, patch: 6)  // pre-v0.20.6 only
    }

    /// Whether `hermes-agent` is an essential skill the host will never let
    /// stay disabled. Landed at v2026.8.27 (0.20.6, commit 3733e4aff5 "fix:
    /// system prompt no longer references tools/skills the session can't
    /// use; hermes-agent skill is always kept"): `ESSENTIAL_SKILLS =
    /// frozenset({"hermes-agent"})` in `agent/skill_utils.py`, and every
    /// read of `skills.disabled` (`get_disabled_skill_names`,
    /// `skills_config.get_disabled_skills`) subtracts it before returning,
    /// while `save_disabled_skills` subtracts it before writing — so a
    /// disable request for this one name is dropped on both read and write
    /// paths, on every surface. Absent at v2026.8.19 (0.20.5), where the
    /// same functions return the raw set unfiltered.
    ///
    /// Scarf has no writer for `skills.disabled` today (`SkillsView` only
    /// renders the raw list Hermes reports), but the raw config.yaml can
    /// still carry a stale/hand-edited `hermes-agent` entry from before
    /// this host was upgraded, or from a manual edit — on a v0.20.6+ host
    /// Hermes ignores that entry entirely, so showing it as "OFF" would be
    /// actively wrong, not just stale UI.
    public var hasEssentialHermesAgentSkill: Bool { isV0206OrLater }

    /// Whether `tavily` is still a selectable web search/extract backend.
    /// **Inverse semantics** — `true` means keep it in the pickers.
    ///
    /// The whole `plugins/web/tavily/` provider (plus its registry, keyless
    /// MCP, and `nous_subscription` entries) was deleted at v2026.8.31
    /// (0.21.0); the keyless free-tier ring comment in `config_defaults.py`
    /// drops from five vendors to four (exa, parallel, firecrawl, keenable)
    /// at the same tag. Present and fully wired at v2026.8.27 (0.20.6), so
    /// this is a genuine v0.21 removal.
    ///
    /// Unknown version keeps the option: selecting a backend a host doesn't
    /// know is recoverable, whereas hiding the row a pre-v0.21 user is
    /// actively using is not. (This differs deliberately from
    /// `hasWebExtractAux`, whose row is a whole sub-editor rather than one
    /// entry in a list.)
    ///
    /// **v0.21.1 puts it back.** `plugins/web/tavily/` was re-added at
    /// v2026.9.7 (commit 428e084dcd) — `git ls-tree v2026.9.7 plugins/web/`
    /// lists it, `v2026.8.31` does not. So the removal window is EXACTLY
    /// v0.21.0: present ≤ v0.20.6, gone at v0.21.0, present again from
    /// v0.21.1. The kept-on-unknown policy is unchanged (`semver == nil`
    /// falls out of the equality and keeps the option).
    public var hasTavilyWebBackend: Bool {
        guard let s = semver else { return true }         // unknown → keep
        return s != SemVer(major: 0, minor: 21, patch: 0) // gone at 0.21.0 only
    }

    /// Whether `keenable` is a selectable web search/extract backend
    /// (`plugins/web/keenable/`, registering search AND extract on
    /// `KeenableWebSearchProvider`). **Floor corrected from the audit
    /// report's "v0.20.6":** `git ls-tree <tag> plugins/web/` across every
    /// tag shows the directory first appearing at v2026.8.19 (0.20.5), not
    /// v2026.8.27 — so gating it at v0.20.6 would hide a working backend
    /// from 0.20.5 hosts. It has been in the keyless free-tier ring the
    /// whole time; Scarf's picker simply never listed it.
    public var hasKeenableWebBackend: Bool { isV0205OrLater }

    /// Whether `platforms.telegram.extra.ignore_root_dm` still has a READER
    /// — i.e. whether the Telegram setup form's "Ignore root DM" row does
    /// anything on this host.
    ///
    /// **A WINDOW, not a floor** (same shape as `hasTavilyWebBackend`).
    /// Walked over every tag and both file locations the reader has had:
    /// it appears at v2026.5.28 (0.15.0)
    /// `gateway/platforms/telegram.py:4879`, moves with the v0.18 plugin
    /// split to `plugins/platforms/telegram/adapter.py` (`:9835` at
    /// v2026.8.31 = 0.21.0, its last tag), and is GONE at v2026.9.7
    /// (0.21.1): a whole-tree `git grep ignore_root_dm v2026.9.7` returns
    /// only `scripts/release.py:798` (a contributor-attribution comment)
    /// and the website docs — no `extra.get("ignore_root_dm")` anywhere in
    /// the shipped code. So the window is `0.15.0 <= v < 0.21.1`.
    ///
    /// Unknown version keeps the row (charter C1: a host whose version
    /// probe has not answered must render exactly what it rendered before
    /// this flag existed, and before it the row was unconditional). The
    /// VALUE is still PARSED on every host, so a downgrade back into the
    /// window finds the user's setting intact. The WRITE is gated by this
    /// same flag (`TelegramSetupViewModel.save`): writing a key whose row
    /// this host never rendered would stamp a value the user was never
    /// shown over whatever config.yaml already held.
    public var hasTelegramIgnoreRootDM: Bool {
        guard let s = semver else { return true }        // unknown → keep
        return s >= SemVer(major: 0, minor: 15, patch: 0)
            && s < SemVer(major: 0, minor: 21, patch: 1)
    }

    /// Whether `steer` is a selectable `display.busy_input_mode` — Enter
    /// injects the typed text into the RUNNING turn rather than
    /// interrupting it or queueing it for the next one.
    ///
    /// Floor v0.12.0, found by walking the READER (not the comment): the
    /// three-way branch `elif _bim == "steer":` first appears at
    /// v2026.4.30 (0.12.0) `cli.py:1946` and is unbroken through
    /// v2026.9.7, where the modularised reader states the whole member set
    /// in one line — `cli.py:2592`
    /// `self.busy_input_mode = _bim if _bim in ("queue", "steer") else "interrupt"`.
    /// (v2026.4.23's `"steer"` hits are the `/steer` SLASH COMMAND, a
    /// different surface; the `interrupt | queue | steer` comment in
    /// `config.py` also lands at v2026.4.30, but a comment is not a
    /// reader.) Below the floor Hermes falls back to `interrupt`, so
    /// offering the option there would let a user pick a mode their host
    /// silently ignores.
    ///
    /// Unknown version HIDES it — the option is absent from today's picker,
    /// and C1 requires an unknown host to keep rendering what it renders
    /// now.
    public var hasBusyInputSteerMode: Bool { atLeastSemver(0, 12, 0) }

    // MARK: v0.21.1 (v2026.9.7) flags
    //
    // A light additive cycle on top of v0.21.0: the state.db schema Scarf
    // reads, the ACP wire, and every argv Scarf issues are unchanged, so
    // everything below is a NEW surface rather than a migration. Each flag
    // was floor-checked BOTH ways — absent at v2026.8.31 (0.21.0), present
    // at v2026.9.7 — with `git -C ~/.hermes/hermes-agent grep <needle>
    // <tag> -- <path>`, per charter C2.
    //
    // Note `hasTavilyWebBackend` above is a v0.21.1 change too, but it lives
    // with the v0.21 removal it reverses so the whole window reads in one
    // place; same for `hasKeenableWebBackend`, whose floor is older still.

    /// `hermes plugins compat [--json]` — report installed plugins that
    /// import pre-decomposition module paths, which stop loading after the
    /// removal date the command reports (v0.21.1+,
    /// `hermes_cli/subcommands/plugins.py:105`, dispatched at
    /// `hermes_cli/plugins_cmd.py:2060`). JSON payload is
    /// `{removal_date, in_effect, plugins: {name: [hits]}}`. **Exits 1 when
    /// plugins are affected** — that is the finding path, not a failure, so
    /// a caller must parse stdout regardless of exit code (same contract as
    /// `cron doctor`). Absent at v2026.8.31, where `plugins_cmd.py` has no
    /// `compat` verb at all, so an older host fails argparse.
    public var hasPluginsCompat: Bool { isV0211OrLater }

    /// `hermes cron create --paused [--paused-reason <text>]` — create a job
    /// already paused, instead of create-then-`cron pause` (v0.21.1+,
    /// `hermes_cli/subcommands/cron.py:84,86`). Prints `Created PAUSED — …`
    /// where an armed job prints `Next run:`, so any output parse must
    /// branch on it. argparse rejects the whole `cron create` on a host
    /// without the flag, so every cron-write path must gate on this.
    public var hasCronCreatePaused: Bool { isV0211OrLater }

    /// `hermes cron create/edit --failure-deliver <target>` and the
    /// corresponding `failure_deliver` job field (v0.21.1+,
    /// `hermes_cli/subcommands/cron.py:33,94`; persisted by
    /// `cron/jobs.py`). Scarf already round-trips the field verbatim through
    /// `HermesCronJob.extra`; this gates SHOWING and WRITING it. Unknown
    /// flag ⇒ argparse rejects the whole invocation, so job-cloning paths
    /// must drop the argv on older hosts rather than pass it through.
    public var hasCronFailureDeliver: Bool { isV0211OrLater }

    /// Cron dispatch diagnostics: the job fields `last_dispatch`
    /// (`{scheduled_at, dispatched_at, kind: on_time|late|catch_up,
    /// lateness_seconds}`) and `last_delivery_unverified`, surfaced by
    /// `cron list` as new `Dispatch:` and `⚠ Delivery UNVERIFIED:` rows
    /// (`hermes_cli/cron.py:204,223`) and by `cron status` as a late-fire
    /// block (`:433-434,498`). v0.21.1+ — absent at v2026.8.31. Read-only
    /// diagnostics, but the two new rows are a text-parser drift risk, so
    /// the parser expectations gate here.
    public var hasCronDispatchDiagnostics: Bool { isV0211OrLater }

    /// `hermes kanban … --completion-contract <contract>`
    /// (`hermes_cli/kanban_parser.py:189`) plus the `completion_contract`
    /// and `last_failure_error` fields in `kanban list --json`
    /// (`hermes_cli/kanban_output.py:23`) — the real failure reason without
    /// a second `kanban show` round-trip. v0.21.1+.
    public var hasKanbanCompletionContract: Bool { isV0211OrLater }

    /// `hermes auth priority <provider> <target> <n>` and `auth refresh
    /// <provider> [target]` — reorder a credential pool and clear one
    /// credential's cooldown (v0.21.1+,
    /// `hermes_cli/subcommands/auth.py:47,50,52`). The same commit adds
    /// `auth add --priority` and an optional target on `auth reset`.
    /// Credential Pools can do neither today.
    public var hasAuthPriority: Bool { isV0211OrLater }

    /// `hermes mcp login <name> --flow {browser,device}` plus the
    /// `mcp_servers.<name>.oauth.flow` config key (v0.21.1+,
    /// `hermes_cli/subcommands/mcp.py:59`; device grant implemented in
    /// `tools/mcp_oauth_device.py`). The device flow prints a verification
    /// URL AND a user code that the user must read, so a Scarf surface for
    /// it has to show the CLI's output rather than a spinner.
    public var hasMCPOAuthFlow: Bool { isV0211OrLater }

    /// `hermes sessions export --no-redact` — the opt-OUT for the forced
    /// redaction a `trace` export applies by default.
    ///
    /// **Floor v0.18.1, the same tag that introduced `--format trace`.** The
    /// round-2 pass floored this at v0.21.1 on the claim that "a walk of all
    /// 32 v2026.* tags puts the first registration at v2026.9.7"; that walk
    /// was wrong. `sessions_export.add_argument("--no-redact",
    /// action="store_true", …)` is `hermes_cli/main.py:13567` at tag
    /// **v2026.7.7** (`pyproject.toml:10` = `0.18.1`) and is absent from
    /// `hermes_cli/main.py` at v2026.7.1 (0.18.0). It is functional there,
    /// not vestigial: `redact_trace = not getattr(args, "no_redact", False)`
    /// at `hermes_cli/main.py:13944` @ v2026.7.7. It is still registered at
    /// every later tag — `hermes_cli/main.py:14245` @ v2026.8.31 (0.21.0),
    /// and after the subcommand split `hermes_cli/subcommands/sessions.py:83`
    /// @ v2026.9.7, read by `_export_trace` as `redact_trace = not
    /// getattr(args, "no_redact", False)` (`hermes_cli/sessions_cmd.py:395`).
    ///
    /// So ten releases below the previous floor DO honour the opt-out, and
    /// force-disabling "Redact secrets" on them was the bug. Below v0.18.1
    /// there is no `trace` format at all (`hasSessionsExportFormats` shares
    /// the floor), so the two gates move together.
    public var hasSessionsExportNoRedact: Bool { isV0181OrLater }

    // MARK: Older floors corrected/added in the v0.21.1 pass
    //
    // Three surfaces the v0.21.1 audit reached for turned out to predate
    // the target by several releases. Gating them at v0.21.1 would hide a
    // working surface on hosts that have it (the `hasKeenableWebBackend`
    // mistake, one release later), so each carries its own floor, found by
    // walking EVERY tag's argparse rather than diffing the two endpoints.

    /// `hermes computer-use permissions status --json` — the normalized
    /// readiness payload `{platform, platform_supported, installed, version,
    /// ready, can_grant, checks: [{label,status,message}], source, error,
    /// accessibility, screen_recording, screen_recording_capturable}`
    /// (`tools/computer_use/permissions.py::computer_use_status`, whose
    /// docstring calls the key order "an API payload contract").
    ///
    /// **Floor is v0.18, not v0.21.1.** The `--json` flag is on the
    /// `permissions status` subparser from v2026.7.1 (0.18.0) onward — in
    /// `hermes_cli/main.py` until v0.21.1 moved it into
    /// `hermes_cli/subcommands/computer_use.py` — and `computer_use_status`
    /// returns the same key set at v2026.7.1 and v2026.9.7. Exits 0 when
    /// `ready`, 1 otherwise, so a caller must read stdout regardless of
    /// exit code.
    public var hasComputerUsePermissionsJSON: Bool { isV018OrLater }

    /// `hermes skills search --json` — a JSON array of
    /// `{name, identifier, source, trust_level, description}` instead of the
    /// Rich table (`hermes_cli/skills_hub.py::do_search`, `as_json`).
    ///
    /// **Floor is v0.17, not v0.21.1.** First tag carrying the flag is
    /// v2026.6.19 (0.17.0), with the same five keys it emits at v2026.9.7.
    /// This matters beyond scripting convenience: the search TABLE has no
    /// `#` column (`Name | Description | Source | Trust | Identifier`), so
    /// Scarf's row parser — written for `skills browse`, which does have
    /// one — discarded every search result on every host. JSON is the fix
    /// AND the only place the full identifier survives unwrapped.
    public var hasSkillsSearchJSON: Bool { isV017OrLater }

    /// `browse-sh` as a `hermes skills browse|search --source` choice
    /// (v0.15+ — first tag v2026.5.28 / 0.15.0, in `main.py` then; today
    /// `hermes_cli/subcommands/skills.py::_SOURCE_CHOICES`).
    public var hasSkillsBrowseSHSource: Bool { isV015OrLater }

    /// The seven PROVIDER `--source` filters — `nvidia`, `openai`,
    /// `anthropic`, `huggingface`, `voltagent`, `gstack`, `minimax` — added
    /// as one block at v2026.7.1 (0.18.0) under the comment "Provider
    /// filters (GitHub taps stored under source=\"github\")". argparse
    /// rejects an unknown `--source` value, so offering one of these to a
    /// pre-v0.18 host turns a search into an exit-2 usage error.
    public var hasSkillsProviderSources: Bool { isV018OrLater }

    /// `hermes debug share -y/--yes` (v0.18+, first tag v2026.7.1).
    ///
    /// From v0.18 `_confirm_upload` (`hermes_cli/debug.py`) hard-EXITS 1 on
    /// a non-TTY without `--yes` — which is every invocation Scarf makes —
    /// so `debug share` could never once have succeeded from the app.
    /// Passing `-y` is what makes it work; the user's consent is the
    /// confirmation sheet, which runs before the argv is built. Pre-v0.18
    /// hosts have no such flag AND no confirmation gate (the upload just
    /// proceeds), so the argv must omit it there or argparse rejects the
    /// whole command.
    public var hasDebugShareYes: Bool { isV018OrLater }

    /// `agent.service_tier` accepts the two BOUNDED fast-mode values `auto`
    /// (fast for the first `agent.fast_auto_seconds`, default 60) and
    /// `cold` (a session's first turn only) alongside the existing
    /// ""/`normal` and `fast`/`priority` (v0.21.1+, `cli.py:281`
    /// `_parse_service_tier_config`, `agent/fast_mode.py:16`
    /// `BOUNDED_MODES`, `hermes_cli/config_defaults.py:119,122`). At
    /// v2026.8.31 the same parser knows only off/priority and LOGS A
    /// WARNING then ignores anything else — so Scarf must not offer these
    /// values to an older host, and its Bool "Fast Mode" toggle must not
    /// overwrite an `auto`/`cold` value it can't represent.
    public var hasServiceTierBoundedModes: Bool { isV0211OrLater }

    /// `telemetry.shared_metrics.send` (default false) and `.endpoint`
    /// (`https://telemetry.nousresearch.com/v1/telemetry`) — the opt-in that
    /// TRANSMITS the locally collected aggregate metrics
    /// (`hermes_cli/config_defaults.py:2070`). v0.21.1+: the sibling
    /// `.enabled` collection switch already existed at v2026.8.31
    /// (`config_defaults.py:3496`), where the block has that key and nothing
    /// else — so this flag is specifically about the two transmission keys,
    /// and about Scarf's Advanced-tab copy, which claims "there is no remote
    /// sink" and is false from v0.21.1 on. Collection stays local while
    /// `send` is false, and `send` alone (without `enabled`) logs an error.
    ///
    /// Named `…Send` rather than the audit's `hasSharedMetricsTelemetry`:
    /// that name is already taken by the v0.20 flag for the sibling
    /// COLLECTION switch, and the two gate different rows.
    public var hasSharedMetricsSend: Bool { isV0211OrLater }

    /// Whether `perplexity` is a selectable web search/extract backend
    /// (v0.21.1+, `plugins/web/perplexity/__init__.py` registering
    /// `PerplexityWebSearchProvider`, whose `provider.py:149,168,197`
    /// implement `name`/`search`/`extract` — so it belongs in BOTH pickers).
    /// Keyed only (`PERPLEXITY_API_KEY`), not a keyless-ring member.
    /// `git ls-tree v2026.8.31 plugins/web/` has no `perplexity` entry.
    public var hasPerplexityWebBackend: Bool { isV0211OrLater }

    // MARK: v0.21.2 (v2026.9.11) flags
    //
    // "The state.db patch release": 986 commits over v0.21.1, verified at
    // the tag on 2026-09-14. SCHEMA_VERSION stays 30, no table is removed and
    // every column Scarf probes is present (`scripts/check-hermes-tables.py
    // --tag v2026.9.11` exits 0); hosted rooms moved to `shared-state.db`,
    // which Scarf never reads; the ACP adapter changed four lines of
    // `/model` provider detection (`acp_adapter/server.py`); no verb or flag
    // Scarf issues was removed and every output marker Scarf judges on is
    // byte-identical. The one behaviour change Scarf must answer is
    // `hermes backup`'s new prune default, below. New verbs (`vault`, `auth
    // upgrade`, `plugins browse|validate`) have no Scarf surface, so no flag.

    /// `hermes backup -k/--keep N` — `hermes_cli/subcommands/backup.py:23-26`
    /// @ v2026.9.11 (`type=int, default=3`), consumed at
    /// `hermes_cli/backup.py:696-698`: after a full backup, delete older
    /// `hermes-backup-*.zip` files in the OUTPUT DIRECTORY beyond the newest
    /// N; `0` keeps everything. Absent at v2026.9.7 (`git show
    /// "v2026.9.7:hermes_cli/subcommands/backup.py"` has no `keep`), where
    /// the flag is an argparse error at exit 2.
    ///
    /// Scarf passes `--keep 0` on hosts that have it: the default output is
    /// `~/hermes-backup-<timestamp>.zip`, so the CLI default would delete a
    /// user's older backups from their home directory on a click that says
    /// "Backup Now" — a deletion nobody asked for. C1: below the floor the
    /// argv is the bare `backup` it has always been; at and above it the only
    /// difference from the CLI is that nothing is pruned.
    public var hasBackupKeep: Bool { isV0212OrLater }

    // MARK: v0.21.3 (v2026.9.14) flags

    /// GPT-Live voice chat mode — Hermes's full-duplex voice frontend that
    /// delegates every real request to the agent. `tools/voice_live.py`
    /// first ships at tag **v2026.9.14** (commit `f923faa0b8`, whose
    /// `pyproject.toml:5` reads `version = "0.21.3"`); `git ls-tree
    /// v2026.9.11 -- tools/voice_live.py` is empty. Scarf's Live Voice
    /// imports that module on the host (`create_webrtc_session`,
    /// `voice_live.py:162-186`) for the SDP exchange, and the
    /// `voice.voice_chat_mode` key it reads is seeded at
    /// `hermes_cli/config_defaults.py:1132` from the same tag.
    ///
    /// This is only HALF of the Live Voice gate: the entry point also needs
    /// the host's parsed `voice.voice_chat_mode` to be gpt-live — see
    /// ``VoiceLiveReadiness``. There is deliberately no host status probe:
    /// a missing OpenAI key surfaces at session start as a setup message,
    /// before anything is billed.
    public var hasGPTLiveVoice: Bool { isV0213OrLater }

    // MARK: Convenience predicates

    /// Whether the connected host is on the v0.11 line or newer. Convenience
    /// for the config-default resolvers that switch on the v0.10 → v0.11
    /// boundary — `agent.gateway_notify_interval` dropped 600 → 180 at tag
    /// v2026.4.23, the same tag that first registers the `gemini` and
    /// `kittentts` TTS providers.
    public var isV011OrLater: Bool { atLeastSemver(0, 11, 0) }

    /// Whether the connected host is on v0.18.1 or newer. Patch-level floor,
    /// same shape as `isV0191OrLater` — tag **v2026.7.7**'s
    /// `pyproject.toml` reads `version = "0.18.1"`, so it is a numbered
    /// release a host can be running, and it is where
    /// `display.show_reasoning`'s shipped default flipped `False` → `True`
    /// (see `HermesConfig.displayShowReasoning(capabilities:)`).
    public var isV0181OrLater: Bool { atLeastSemver(0, 18, 1) }

    /// Whether the connected host is on the v0.13 line or newer. Convenience
    /// for UI copy that needs to switch on the v0.12 → v0.13 boundary without
    /// proxying through a feature-specific flag (e.g. "v0.13 features active"
    /// badges, redaction default-state hints). Equivalent to any individual
    /// v0.13 flag; prefer this when the call site isn't actually about a
    /// specific feature.
    public var isV013OrLater: Bool { atLeastSemver(0, 13, 0) }

    /// Whether the connected host is on the v0.14 line or newer. Convenience
    /// for UI copy that toggles on the v0.13 → v0.14 boundary without
    /// proxying through a feature-specific flag (e.g. "v0.14 features"
    /// badges, cross-session-cache hints in Settings).
    public var isV014OrLater: Bool { atLeastSemver(0, 14, 0) }

    /// Whether the connected host is on the v0.15 line or newer. Convenience
    /// for UI copy that toggles on the v0.14 → v0.15 boundary without
    /// proxying through a feature-specific flag.
    public var isV015OrLater: Bool { atLeastSemver(0, 15, 0) }

    /// Whether the connected host is on the v0.16 line or newer. Convenience
    /// for UI copy that toggles on the v0.15 → v0.16 boundary without
    /// proxying through a feature-specific flag.
    public var isV016OrLater: Bool { atLeastSemver(0, 16, 0) }

    /// Whether the connected host is on the v0.17 line or newer. Convenience
    /// for UI copy that toggles on the v0.16 → v0.17 boundary without
    /// proxying through a feature-specific flag.
    public var isV017OrLater: Bool { atLeastSemver(0, 17, 0) }

    /// Whether the connected host is on the v0.18 line or newer. Convenience
    /// for UI copy that toggles on the v0.17 → v0.18 boundary without
    /// proxying through a feature-specific flag.
    public var isV018OrLater: Bool { atLeastSemver(0, 18, 0) }

    /// Whether the connected host is on the v0.19 line or newer. Convenience
    /// for UI copy that toggles on the v0.18 → v0.19 boundary without
    /// proxying through a feature-specific flag.
    public var isV019OrLater: Bool { atLeastSemver(0, 19, 0) }

    /// Whether the connected host is on v0.19.1 or newer. Patch-level floor
    /// for the surfaces that first shipped in tag **v2026.7.30**, whose
    /// `pyproject.toml:5` reads `version = "0.19.1"` — NOT an unnumbered
    /// pre-release. The v0.20 audit mis-read that tag as "between v0.19.0
    /// and v0.20.0, so round the floor up to v0.20"; walking the tags shows
    /// v2026.7.20 = 0.19.0, v2026.7.30 = 0.19.1, v2026.8.3 = 0.20.0, so
    /// v0.19.1 is itself a numbered release a host can be running and the
    /// floor belongs here. See `hasApprovalSmartPolicy` and its siblings.
    public var isV0191OrLater: Bool { atLeastSemver(0, 19, 1) }

    /// Whether the connected host is on the v0.20 line or newer. Convenience
    /// for UI copy that toggles on the v0.19 → v0.20 boundary without
    /// proxying through a feature-specific flag.
    public var isV020OrLater: Bool { atLeastSemver(0, 20, 0) }

    /// Whether the connected host is on v0.20.1 or newer. Patch-level floor
    /// for the surfaces that first shipped in tag **v2026.8.13**, whose
    /// `pyproject.toml` reads `version = "0.20.1"`: `hermes_cli/personality.py`
    /// (the file does not exist at v2026.8.3 = 0.20.0) and
    /// `cron/jobs.py:482` `_has_pause_marker` (absent at v2026.8.3, present
    /// at v2026.8.13 and every later tag). See `hasBuiltinPersonalitiesInCode`
    /// and `hasCronPauseMarkerGate` — both were floored at v0.20.4, which
    /// withheld them from every 0.20.1–0.20.3 host that has them.
    public var isV0201OrLater: Bool { atLeastSemver(0, 20, 1) }

    /// Whether the connected host is on v0.20.2 or newer. Patch-level floor
    /// for the raised delegation ceilings: tag v2026.8.16 (v0.20.2) is where
    /// `hermes_cli/config_defaults.py:1821` first reads
    /// `"max_iterations": 250` and `:1846` `"max_concurrent_children": 10`
    /// (at v2026.8.13 / v0.20.1 those same keys were `:1764` = 50 and
    /// `:1789` = 3), and where `hermes_cli/config_migrations.py:757`
    /// (`_migrate_to_36`) and `:787` (`_migrate_to_37`) are introduced.
    /// See `HermesConfig.displayDelegationMaxIterations`.
    public var isV0202OrLater: Bool { atLeastSemver(0, 20, 2) }

    /// Whether the connected host is on v0.20.3 or newer. Patch-level floor:
    /// tag v2026.8.16.2 is where `tools/bot_mode_probe.py` — and with it the
    /// `ui_meta['hermes-bots']` convention — first ships. See `hasBotMode`.
    public var isV0203OrLater: Bool { atLeastSemver(0, 20, 3) }

    /// Whether the connected host is on v0.20.4 or newer. Patch-level floor
    /// — v0.20.0 through v0.20.3 hosts satisfy `isV020OrLater` but lack the
    /// v0.20.4 surface, so this must be checked with `atLeastSemver(0, 20,
    /// 4)` rather than the minor-only `isV020OrLater`.
    public var isV0204OrLater: Bool { atLeastSemver(0, 20, 4) }

    /// Whether the connected host is on v0.20.5 or newer. Patch-level floor,
    /// same rationale as `isV0204OrLater` — v0.20.0 through v0.20.4 hosts
    /// satisfy `isV020OrLater` but lack the v0.20.5 surface (the `version`
    /// subcommand removal, `cron --reasoning-effort`), so this must be checked
    /// with `atLeastSemver(0, 20, 5)` rather than the minor-only
    /// `isV020OrLater`.
    public var isV0205OrLater: Bool { atLeastSemver(0, 20, 5) }

    /// `hermes skills uninstall --yes` — the non-interactive confirmation.
    ///
    /// Floor walked across every tag over both parser locations
    /// (`hermes_cli/main.py`, then `hermes_cli/subcommands/skills.py`): the
    /// flag first appears at **v2026.8.19 = 0.20.5** and is consumed as
    /// `do_uninstall(a.name, skip_confirm=getattr(a, "yes", False))`
    /// (`hermes_cli/skills_hub.py:1324` at v2026.9.7). Below the floor the
    /// verb prompts through `input()` and argparse exits 2 on the flag, so
    /// those hosts still need the piped `"y\n"`.
    public var hasSkillsUninstallYes: Bool { isV0205OrLater }

    /// Whether the connected host is on v0.20.6 or newer. Patch-level floor,
    /// same rationale as `isV0204OrLater`/`isV0205OrLater`. v0.20.6
    /// (v2026.8.27) is the tag that sits between v0.20.5 and v0.21.0 and
    /// carries several surfaces the v0.21 release notes advertise —
    /// `cron incidents`, `cron resume --run-now/--at`, `--deliver bot-chat`,
    /// the `browser` subcommand — so those gate here rather than on
    /// `isV021OrLater`, which would hide them from v0.20.6 hosts that have
    /// them.
    public var isV0206OrLater: Bool { atLeastSemver(0, 20, 6) }

    /// Whether the connected host is on the v0.21 line or newer. Convenience
    /// for UI copy that toggles on the v0.20 → v0.21 boundary without
    /// proxying through a feature-specific flag. Minor-level floor, like
    /// `isV020OrLater` — the v0.21.0 surfaces gated on it are absent from
    /// every v0.20.x host including v0.20.6.
    public var isV021OrLater: Bool { atLeastSemver(0, 21, 0) }

    /// Whether the connected host is on v0.21.1 or newer. Patch-level floor,
    /// same rationale as `isV0205OrLater`/`isV0206OrLater` — every v0.21.0
    /// host satisfies `isV021OrLater` but lacks the whole v0.21.1 surface
    /// (`plugins compat`, `cron --paused`/`--failure-deliver`, `auth
    /// priority`, `mcp login --flow`, bounded fast-mode tiers, the
    /// Perplexity backend), so those must be checked with `atLeastSemver(0,
    /// 21, 1)` rather than the minor-only `isV021OrLater`.
    public var isV0211OrLater: Bool { atLeastSemver(0, 21, 1) }

    /// Whether the connected host is on v0.21.2 or newer. Patch-level floor
    /// for the v0.21.2 group (`backup --keep`), same rationale as
    /// `isV0211OrLater`: a v0.21.1 host satisfies every minor-level check
    /// and lacks the flag.
    public var isV0212OrLater: Bool { atLeastSemver(0, 21, 2) }

    /// Whether the connected host is on v0.21.3 or newer. Patch-level floor
    /// for the v0.21.3 group (GPT-Live voice), same rationale as
    /// `isV0212OrLater`.
    public var isV0213OrLater: Bool { atLeastSemver(0, 21, 3) }

    /// Public form of the private floor test, for tables that carry their
    /// own floors as data (see `KnownPlatforms.minimumVersion`) rather than
    /// as one named flag each. An UNDETECTED host is below every floor.
    public func isAtLeast(_ version: SemVer) -> Bool {
        guard let s = semver else { return false }
        return s >= version
    }

    private func atLeastSemver(_ major: Int, _ minor: Int, _ patch: Int) -> Bool {
        atLeast(SemVer(major: major, minor: minor, patch: patch))
    }

    /// Same test as ``atLeastSemver(_:_:_:)`` against an already-built floor,
    /// for the floors that are shared with a non-Bool consumer.
    private func atLeast(_ floor: SemVer) -> Bool {
        guard let s = semver else { return false }
        return s >= floor
    }

    public struct SemVer: Sendable, Equatable, Comparable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String { "\(major).\(minor).\(patch)" }

        public static func < (a: SemVer, b: SemVer) -> Bool {
            if a.major != b.major { return a.major < b.major }
            if a.minor != b.minor { return a.minor < b.minor }
            return a.patch < b.patch
        }
    }

    public struct DateVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public var description: String { "\(year).\(month).\(day)" }

        public static func < (a: DateVersion, b: DateVersion) -> Bool {
            if a.year != b.year { return a.year < b.year }
            if a.month != b.month { return a.month < b.month }
            return a.day < b.day
        }
    }

    /// Parse a `Hermes Agent v0.12.0 (2026.4.30)` line out of `hermes --version`
    /// output. Tolerates leading/trailing whitespace, extra header lines
    /// (e.g. `Project:`, `Python:`), and the absence of the parenthesized
    /// date suffix.
    ///
    /// Returns `.empty` when no recognizable version line is present so
    /// callers don't have to special-case nil.
    public static func parse(_ output: String) -> HermesCapabilities {
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("Hermes Agent v") else { continue }
            return parseLine(line)
        }
        return .empty
    }

    /// `Hermes Agent v0.12.0 (2026.4.30)` → semver + date. Returns `.empty`
    /// when the line doesn't match. Public for unit tests; production callers
    /// should use `parse(_:)`.
    public static func parseLine(_ line: String) -> HermesCapabilities {
        // Locate the "v" right after "Hermes Agent ". Don't anchor at line
        // start — older builds prefix with ANSI color codes Scarf would
        // need to strip.
        guard let vRange = line.range(of: "Hermes Agent v") else { return .empty }
        let tail = String(line[vRange.upperBound...])

        // Read digits separated by dots until we hit non-version content.
        // First three components are semver. A trailing `(Y.M.D)` is the
        // date version.
        let semverEnd = tail.firstIndex(where: { c in
            !(c.isNumber || c == ".")
        }) ?? tail.endIndex
        let semverStr = String(tail[..<semverEnd])
        let semverParts = semverStr.split(separator: ".").compactMap { Int($0) }
        guard semverParts.count >= 3 else { return .empty }
        // Fail CLOSED on a shape this parser does not actually recognise.
        // Hermes's semver major has been `0` at every tagged release and the
        // only other plausible spelling for years is a small single digit, so
        // a major outside 0...9 is not a Hermes version — it is the DATE
        // version (`v2026.9.7`, which a wrapper or shim on PATH can emit,
        // and which parsed as `SemVer(2026, 9, 7)`), or a vendored fork's
        // own scheme. Degrading that to "newer than every floor" lit up
        // every gate in this file INCLUDING the write and argv ones
        // (`hasCronCreatePaused`, `hasConfigDottedKeyEscape`,
        // `hasCronFailureDeliver`), which is the unsafe direction: C1's
        // contract is that an unknown host renders as the least-capable one.
        // `.empty` is exactly what a failed probe yields, so the caller
        // needs no new case. Alan's round-2 decision 7, 2026-09-10.
        guard (0...9).contains(semverParts[0]) else { return .empty }
        let semver = SemVer(
            major: semverParts[0],
            minor: semverParts[1],
            patch: semverParts[2]
        )

        // Optional date suffix.
        var dateVersion: DateVersion?
        if let openParen = tail.firstIndex(of: "("),
           let closeParen = tail.firstIndex(of: ")"),
           openParen < closeParen {
            let dateStr = tail[tail.index(after: openParen)..<closeParen]
            let dateParts = dateStr.split(separator: ".").compactMap { Int($0) }
            if dateParts.count == 3 {
                dateVersion = DateVersion(
                    year: dateParts[0],
                    month: dateParts[1],
                    day: dateParts[2]
                )
            }
        }

        return HermesCapabilities(
            versionLine: line,
            semver: semver,
            dateVersion: dateVersion
        )
    }
}

/// Per-server, observable view of the host's capability flags. One per
/// `ContextBoundRoot` (Mac) / iOS scene root, injected via `.environment(_:)`.
///
/// The store no longer owns detection — `HermesVersionCache` does, so this
/// window's probe is shared with every other probe site (template install,
/// fleet apply, other windows on the same host) and survives relaunches.
/// The store's job is the *lifecycle*:
///
/// 1. **Optimistic seed.** On init, publish the last-known version for this
///    connection (persisted from a previous launch) so capability-gated UI
///    doesn't flash empty on cold start. `isProvisional` is `true` while that
///    value is unverified.
/// 2. **Reconcile.** When the (shared, deduped) probe answers, replace the
///    seed with ground truth and clear `isProvisional` — so a host that was
///    *downgraded* since last launch loses the UI it no longer supports.
/// 3. **Fall back.** If the probe fails, keep the last-known value (flagged
///    provisional) and, failing that, `.empty` — the original conservative
///    hide-everything default.
///
/// Not thread-safe across instances — it's `@MainActor`; the probe itself is
/// detached so we never block MainActor.
@Observable
@MainActor
public final class HermesCapabilitiesStore {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "HermesCapabilities")
    #endif

    public private(set) var capabilities: HermesCapabilities = .empty
    public private(set) var isLoading = true

    /// `true` when `capabilities` came from the persisted last-known version
    /// rather than a probe that completed in this session. UI that wants to
    /// be honest about it (the Health diagnostics strip) can say "remembered".
    public private(set) var isProvisional = false

    public let context: ServerContext
    private let cache: HermesVersionCache
    private var refreshTask: Task<Void, Never>?
    /// Guards against an older in-flight load clobbering a newer one's result
    /// (e.g. a slow initial probe landing after the user hit "Re-detect").
    private var generation = 0

    public init(context: ServerContext, cache: HermesVersionCache = .shared) {
        self.context = context
        self.cache = cache

        // Seed synchronously: an in-process result if some other call site
        // already probed this host, else the persisted last-known value.
        if let hit = cache.cached(for: context) {
            capabilities = hit
            isLoading = false
        } else {
            let remembered = cache.lastKnown(for: context)
            capabilities = remembered
            isProvisional = remembered.detected
        }

        // Kick off detection. Task captures `[weak self]`, so if the store is
        // freed before detection completes the closure simply no-ops.
        refreshTask = Task { [weak self] in
            await self?.load(force: false)
        }
    }

    // MARK: - Analytics

    /// Versions already reported this process, keyed by `"<semver>|<flag>"`.
    ///
    /// Every store on every window probes its own host, `refresh()` re-probes
    /// on demand, and the version almost never changes — so an event per
    /// refresh would be pure repetition. `@MainActor` (inherited from the
    /// enclosing class) is the whole synchronization story; no lock needed.
    ///
    /// The provisional flag is part of the key rather than folded away: a
    /// remembered version that is later confirmed by a real probe is a
    /// genuinely different fact, and the pair is still bounded at two events
    /// per version per process.
    private static var reportedVersions: Set<String> = []

    /// Emit `hermes_version_detected` the first time this process sees this
    /// (version, provisional) pair.
    ///
    /// Only `semver` is recorded — never `versionLine`, which is the raw
    /// `hermes --version` banner and can carry arbitrary text from the host.
    /// A build we can't parse a semver out of reports nothing at all rather
    /// than reporting something unbounded.
    static func noteDetectedVersion(_ capabilities: HermesCapabilities, provisional: Bool) {
        guard let semver = capabilities.semver else { return }
        let version = semver.description
        let key = "\(version)|\(provisional)"
        guard reportedVersions.insert(key).inserted else { return }
        ScarfAnalytics.record("hermes_version_detected", [
            "version": version,
            "provisional": provisional ? "true" : "false",
        ])
    }

    /// Fallback kinds already reported by ``noteProbeFailed(fallback:)`` this
    /// process. Same static + `@MainActor` (inherited) pattern, and the same
    /// rationale, as ``reportedVersions``: a store is built per window, every
    /// window re-probes the same host, and a host that is simply unreachable
    /// fails every probe — so an event per failed probe per store is pure
    /// repetition of one fact. Bounded at two events per process (the two
    /// fallback kinds).
    private static var reportedProbeFailures: Set<String> = []

    /// Emit `hermes_probe_failed` the first time this process falls back in
    /// this way.
    static func noteProbeFailed(fallback: String) {
        guard reportedProbeFailures.insert(fallback).inserted else { return }
        ScarfAnalytics.record("hermes_probe_failed", ["fallback": fallback])
    }

    /// Test hook: forget everything ``noteDetectedVersion(_:provisional:)``
    /// and ``noteProbeFailed(fallback:)`` have reported, so a test can
    /// exercise the dedupe from a clean slate.
    static func resetReportedVersionsForTesting() {
        reportedVersions = []
        reportedProbeFailures = []
    }

    /// Re-probe this host, bypassing the memoized result. Use after
    /// `hermes update` or when the user asks to re-detect.
    public func refresh() async {
        // Let the init-time load finish first: if the forced load interleaved
        // with it, the generation guard could leave the older load's
        // `isLoading = true` standing after refresh() returns. Awaiting it
        // also makes "everything has settled when refresh() returns" hold.
        await refreshTask?.value
        await load(force: true)
    }

    private func load(force: Bool) async {
        generation += 1
        let gen = generation
        // Don't flash "Detecting…" for a load that's already answered by the
        // in-process cache — only a forced or genuinely cold load is a wait.
        if force || cache.cached(for: context) == nil { isLoading = true }

        let probed = force
            ? await cache.refresh(for: context)
            : await cache.capabilities(for: context)

        // A newer load started while we were awaiting — its answer wins.
        guard gen == generation else { return }

        if probed.detected {
            capabilities = probed
            isProvisional = false
            Self.noteDetectedVersion(probed, provisional: false)
        } else {
            // Probe failed. Prefer the last-known version over blanking the
            // whole UI; `.empty` (conservative default) when we've never
            // successfully probed this connection.
            let remembered = cache.lastKnown(for: context)
            capabilities = remembered
            isProvisional = remembered.detected
            Self.noteProbeFailed(fallback: remembered.detected ? "last_known" : "empty")
            if remembered.detected {
                // The version the UI is actually gated on, flagged as
                // unverified — otherwise a host that only ever answers from
                // the persisted cache would look undetectable.
                Self.noteDetectedVersion(remembered, provisional: true)
            }
        }
        isLoading = false

        #if canImport(os)
        if probed.detected {
            logger.info("Hermes \(probed.versionLine, privacy: .public) detected on \(self.context.displayName, privacy: .public)")
        } else if capabilities.detected {
            logger.warning("Hermes version probe failed on \(self.context.displayName, privacy: .public); using last-known \(self.capabilities.versionLine, privacy: .public)")
        } else {
            logger.warning("Hermes version not detected on \(self.context.displayName, privacy: .public)")
        }
        #endif
    }
}

// MARK: - SwiftUI environment wiring

#if canImport(SwiftUI)
import SwiftUI

private struct HermesCapabilitiesStoreKey: EnvironmentKey {
    static let defaultValue: HermesCapabilitiesStore? = nil
}

extension EnvironmentValues {
    /// The active server's capability store. `nil` outside the per-server
    /// `ContextBoundRoot`. Callers should treat `nil` and `.empty` capabilities
    /// the same — defensive code for harness scenarios (Previews, smoke tests).
    public var hermesCapabilities: HermesCapabilitiesStore? {
        get { self[HermesCapabilitiesStoreKey.self] }
        set { self[HermesCapabilitiesStoreKey.self] = newValue }
    }
}

extension View {
    /// Inject a `HermesCapabilitiesStore` into the environment. Mirrors the
    /// usual `.environment(_:)` shape but routes through the typed key
    /// above so callers don't need to import the key.
    public func hermesCapabilities(_ store: HermesCapabilitiesStore) -> some View {
        environment(\.hermesCapabilities, store)
    }
}
#endif
