import Foundation
import Observation
#if canImport(os)
import os
#endif

/// What this Hermes installation can do, derived from `hermes --version`.
///
/// Scarf tracks Hermes feature releases by date-version + semver. v0.12 added
/// a dozen surfaces (Curator, Kanban, multimodal ACP, ...) and removed a few
/// (`flush_memories` aux task); v0.13 added Persistent Goals, ACP `/queue`,
/// Kanban diagnostics + recovery UX, Curator archive/prune, Google Chat (20th
/// platform), cross-platform allowlists, MCP SSE transport, Cron `no_agent`
/// mode, Web Tools per-capability backends, Profiles `--no-skills`, and a
/// handful of UX additions; v0.14 launched Windows beta + PyPI, OpenAI-compatible
/// local proxy, two new platforms (LINE + SimpleX), two new providers (xAI OAuth +
/// NovitaAI), new search backends, and /subgoal + YOLO mode; v0.15 added chat-scoped
/// Kanban, Kanban maturation, ntfy platform, xAI web search + TTS tags, Azure Entra
/// auth, Bitwarden secrets, hermes audit, skill bundles, and MCP mTLS; v0.16 adds
/// sessions rename/optimize, kanban goal-mode, insights analytics, and dashboard
/// web-UI. UI that branches on these surfaces calls the boolean accessors here so
/// older Hermes installs degrade silently instead of throwing on an unknown CLI
/// subcommand.
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
    public var hasFallbackCommand: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes kanban` task board CLI (v0.12+).
    public var hasKanban: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes -z <prompt>` non-interactive one-shot mode (v0.12+).
    public var hasOneShot: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes skills install <https-url>` direct-URL install (v0.12+).
    public var hasSkillURLInstall: Bool { atLeastSemver(0, 12, 0) }

    /// ACP `session/prompt` accepts image content blocks (v0.12+).
    public var hasACPImagePrompts: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes update --check` preflight (v0.12+).
    public var hasUpdateCheck: Bool { atLeastSemver(0, 12, 0) }

    /// Pluggable TTS providers including native Piper (v0.12+).
    public var hasPiperTTS: Bool { atLeastSemver(0, 12, 0) }

    /// `terminal.backend = vercel` Vercel Sandbox option (v0.12+).
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
    public var hasTeamsPlatform: Bool { atLeastSemver(0, 12, 0) }
    public var hasYuanbaoPlatform: Bool { atLeastSemver(0, 12, 0) }

    /// Cron jobs accept `--workdir` and `--context-from` flags (v0.12+).
    public var hasCronWorkdir: Bool { atLeastSemver(0, 12, 0) }

    /// `prompt_caching.cache_ttl` config knob (v0.12+).
    public var hasPromptCacheTTL: Bool { atLeastSemver(0, 12, 0) }

    /// `redaction.enabled` is now off by default in v0.12 — Scarf surfaces
    /// the toggle so users can flip it back on. v0.13 flips the server-side
    /// default back to ON; the toggle remains so users on v0.13 can opt out.
    public var hasRedactionToggle: Bool { atLeastSemver(0, 12, 0) }

    // MARK: v0.13 (v2026.5.7) flags

    /// `/goal` slash command + Persistent Goals + Checkpoints v2 single-store
    /// (v0.13+). Used by RichChatViewModel to add `/goal` to the
    /// non-interruptive command list and to render the "Goal locked" pill in
    /// the chat header.
    public var hasGoals: Bool { atLeastSemver(0, 13, 0) }

    /// `/queue` slash command in the ACP adapter (v0.13+). Queues a prompt
    /// to run after the current turn completes without interrupting.
    public var hasACPQueue: Bool { atLeastSemver(0, 13, 0) }

    /// `/steer` runs as a regular prompt on idle ACP sessions (v0.13+). Pre-
    /// v0.13 hosts silently no-op `/steer` when no turn is in flight; with
    /// this flag on, Scarf can surface `/steer` even when the agent isn't
    /// mid-turn without confusing UX.
    public var hasACPSteerOnIdle: Bool { atLeastSemver(0, 13, 0) }

    /// Kanban v0.13 reliability surface: hallucination gate on worker-created
    /// cards, generic diagnostics engine, per-task `max_retries`, multiline
    /// title/body create, `auto_blocked_reason` on blocked tasks, darwin
    /// zombie detection. All read through the `kanban show` JSON surface.
    public var hasKanbanDiagnostics: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes curator archive`, `prune`, and `list-archived` subcommands
    /// (v0.13+). The synchronous manual `hermes curator run` lives behind
    /// this flag too — pre-v0.13 `run` returns immediately and the work
    /// happens in the background.
    public var hasCuratorArchive: Bool { atLeastSemver(0, 13, 0) }

    /// Google Chat — 20th messaging-gateway platform (v0.13+).
    public var hasGoogleChatPlatform: Bool { atLeastSemver(0, 13, 0) }

    /// Cross-platform allowlist keys: `allowed_channels` (Slack / Mattermost
    /// / Google Chat), `allowed_chats` (Telegram / WhatsApp), `allowed_rooms`
    /// (Matrix / DingTalk). Settable per platform in `config.yaml` (v0.13+).
    public var hasGatewayAllowlists: Bool { atLeastSemver(0, 13, 0) }

    /// `busy_ack_enabled` config to suppress per-message "agent is working…"
    /// acks across platforms (v0.13+).
    public var hasGatewayBusyAckToggle: Bool { atLeastSemver(0, 13, 0) }

    /// Per-platform `gateway_restart_notification` flag controls whether the
    /// platform posts a "Gateway restarted" notice on boot (v0.13+).
    public var hasGatewayRestartNotification: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes gateway list` cross-profile status verb (v0.13+). Lets Scarf
    /// show which profile is currently running which platform.
    public var hasGatewayList: Bool { atLeastSemver(0, 13, 0) }

    /// MCP servers can use SSE transport (v0.13+). Adds an `sse_read_timeout`
    /// knob alongside the existing stdio/pipe transports.
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

    /// Context compression count surfaced in the status feed (v0.13+). Scarf
    /// renders it next to the token count in the chat status bar.
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
    public var hasVideoAnalyze: Bool { atLeastSemver(0, 13, 0) }

    /// `transform_llm_output` plugin hook for shaping LLM output before the
    /// conversation receives it (v0.13+). Plugin-author concern; Scarf's
    /// PluginsView surfaces it as a documented hook in plugin metadata.
    public var hasTransformLLMOutputHook: Bool { atLeastSemver(0, 13, 0) }

    /// ACP `session/set_model` JSON-RPC method (v0.13+). Lets Scarf
    /// switch the model on a live session — used at session boot to
    /// apply a project's bound model preset, and at user-tap time
    /// from the chat header to swap mid-conversation. Pre-v0.13
    /// hosts ignore the call and stay on the config.yaml default.
    public var hasACPSetSessionModel: Bool { atLeastSemver(0, 13, 0) }

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
    // path under `hasACPSetSessionModel` (v0.13).

    /// `/subgoal` slash command — appends user-specified success criteria
    /// to the active `/goal` loop. Argument forms: `<text>`, `remove N`,
    /// `clear` (v0.14+). Available in ACP and gateway contexts. Scarf
    /// renders the active subgoals as a trailing line under the goal pill
    /// in `SessionInfoBar`.
    public var hasSubgoal: Bool { atLeastSemver(0, 14, 0) }

    /// `/yolo` slash command — toggles YOLO mode (skip all dangerous
    /// command approvals) for the current session (v0.14+). Available
    /// in ACP. Pairs with the YOLO warning banner driven by
    /// `hasYOLOWarning`.
    public var hasYOLOSlashCommand: Bool { atLeastSemver(0, 14, 0) }

    /// `/sessions` slash command — browse and resume previous sessions
    /// from inside an active chat (v0.14+). Scarf already exposes session
    /// browse via the sidebar, but the literal slash command is a v0.14
    /// addition surfaced in the slash menu for parity.
    public var hasSessionsSlashCommand: Bool { atLeastSemver(0, 14, 0) }

    /// `/codex-runtime` slash command — toggle Codex app-server runtime
    /// for OpenAI/Codex models (v0.14+). Argument forms:
    /// `[auto|codex_app_server]`. Forward-compat flag — Scarf surfaces it
    /// in the slash menu so users on Codex models can flip the runtime
    /// without leaving chat.
    public var hasCodexRuntimeSlashCommand: Bool { atLeastSemver(0, 14, 0) }

    /// xAI Grok OAuth (SuperGrok) provider — overlay-only, OAuth-external
    /// auth, base URL `https://api.x.ai/v1` (v0.14+). Wire ID is
    /// `xai-oauth` (canonical); `x-ai-oauth` / `grok-oauth` /
    /// `xai-grok-oauth` are accepted aliases.
    public var hasGrokOAuthProvider: Bool { atLeastSemver(0, 14, 0) }

    /// NovitaAI inference provider (v0.14+). Overlay-only, API-key auth,
    /// base URL `https://api.novita.ai/v3/openai`. Wire ID is `novita`
    /// (canonical); `novita-ai` / `novitaai` are aliases.
    public var hasNovitaProvider: Bool { atLeastSemver(0, 14, 0) }

    /// LINE Messaging API — 21st gateway platform (v0.14+). Wire ID `line`.
    public var hasLINEPlatform: Bool { atLeastSemver(0, 14, 0) }

    /// SimpleX Chat — 22nd gateway platform (v0.14+). Wire ID `simplex`.
    /// Requires a local `simplex-chat` daemon running in WebSocket mode.
    public var hasSimpleXPlatform: Bool { atLeastSemver(0, 14, 0) }

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
    public func supportsCronDeliver(_ deliver: String?) -> Bool {
        guard deliver == "all" else { return true }
        return hasCronDeliverAll
    }

    /// Discord plugin reads recent channel history when joining a thread
    /// (default on in v0.14+). Scarf surfaces the toggle so users can
    /// disable the backfill for noisy channels.
    public var hasDiscordHistoryBackfill: Bool { atLeastSemver(0, 14, 0) }

    /// OpenRouter Pareto Code router knob `openrouter.min_coding_score`
    /// (0.0–1.0, default 0.65) — routes to the cheapest model meeting the
    /// quality bar (v0.14+). Used together with the
    /// `openrouter/pareto-code` model alias.
    public var hasOpenRouterParetoCoder: Bool { atLeastSemver(0, 14, 0) }

    /// Custom provider `api_mode` field — explicit `chat_completions` /
    /// `anthropic_messages` / etc. selection persisted per provider
    /// (v0.14+). Pre-v0.14 hosts inferred from base URL.
    public var hasCustomProviderAPIMode: Bool { atLeastSemver(0, 14, 0) }

    /// Plugin `tool_override` flag — plugins can replace built-in tools
    /// (v0.14+). Scarf reads the manifest field to render a badge in
    /// `PluginsView`.
    public var hasPluginToolOverride: Bool { atLeastSemver(0, 14, 0) }

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
    public var hasQwenCloudDisplayName: Bool { atLeastSemver(0, 14, 0) }

    /// Cross-session 1-hour Claude prompt cache shared across sessions
    /// on Anthropic / OpenRouter / Nous Portal (v0.14+). Server-side
    /// behavior; Scarf surfaces it as a documentation note in Settings →
    /// Prompt Caching when on a v0.14 host.
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
    public var hasNtfyPlatform: Bool { atLeastSemver(0, 15, 0) }

    /// Opt-in `tts.xai.auto_speech_tags` — inserts light `[pause]` tags
    /// between sentences/paragraphs for more natural xAI TTS. Default OFF.
    public var hasXAITTSAutoSpeechTags: Bool { atLeastSemver(0, 15, 0) }

    /// Microsoft Entra ID auth for Azure AI Foundry — config knob
    /// `model.auth_mode = "entra_id"` (+ `model.entra.scope`); credentials
    /// flow through the Azure SDK env chain (`DefaultAzureCredential`).
    public var hasAzureEntraAuth: Bool { atLeastSemver(0, 15, 0) }

    /// Bitwarden Secrets Manager — `secrets.bitwarden.*` config + a
    /// bootstrap token (`BWS_ACCESS_TOKEN`) replacing per-provider keys.
    public var hasBitwarden: Bool { atLeastSemver(0, 15, 0) }

    /// `hermes audit` — on-demand OSV.dev supply-chain audit verb.
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
    public var hasSkillHubFreshness: Bool { atLeastSemver(0, 15, 0) }

    /// ACP session edit auto-approval modes — `session/set_mode` with
    /// mode IDs `default` / `accept_edits` / `dont_ask` (advertised in
    /// `session/new`'s `modes`). Sensitive paths always still prompt.
    public var hasSessionEditAutoApproval: Bool { atLeastSemver(0, 15, 0) }

    // MARK: v0.16 (v2026.6.5) flags

    /// `hermes sessions rename <id> <title>` — rename an existing session
    /// (v0.16+). Surfaced in the session browser context menu.
    public var hasSessionsRename: Bool { atLeastSemver(0, 16, 0) }

    /// `hermes sessions optimize` — compact the FTS index and VACUUM the
    /// sessions database (v0.16+). Exposed in the Health / Maintenance view.
    public var hasSessionsOptimize: Bool { atLeastSemver(0, 16, 0) }

    /// Kanban tasks carry `goal_mode` (boolean) and `goal_max_turns` (optional
    /// integer) columns for Ralph-style goal loops (v0.16+). Lets the kanban
    /// surface allow users to dispatch a task as a persistent goal-seeking
    /// worker with a turn budget instead of a one-shot execution.
    public var hasKanbanGoalMode: Bool { atLeastSemver(0, 16, 0) }

    /// `hermes insights` — on-demand analytics verb showing agent usage
    /// statistics across all sessions and projects (v0.16+). Surfaced in a
    /// dedicated sidebar destination alongside existing reports.
    public var hasInsightsCommand: Bool { atLeastSemver(0, 16, 0) }

    /// `hermes dashboard` — web-UI backend verb for the desktop dashboard
    /// application (v0.16+). Scarf doesn't directly invoke this; it documents
    /// the version boundary for dashboard-aware installs.
    public var hasDashboardCommand: Bool { atLeastSemver(0, 16, 0) }

    // MARK: v0.17 (v2026.6.19) flags

    /// `curator.consolidate` config key — the LLM skill-consolidation pass is
    /// now OPT-IN (default off); deterministic pruning stays default-on
    /// (v0.17+). Surfaced as a Settings toggle so users can re-enable the merge
    /// pass that ran automatically before v0.17.
    public var hasCuratorConsolidate: Bool { atLeastSemver(0, 17, 0) }

    /// `max_concurrent_sessions` top-level config key — optional cap on
    /// simultaneously-active chat sessions, with automatic cleanup of the
    /// oldest when exceeded (v0.17+). `0`/empty means unbounded.
    public var hasMaxConcurrentSessions: Bool { atLeastSemver(0, 17, 0) }

    /// `photon` gateway platform — iMessage via Photon Spectrum (device-code
    /// OAuth + local gRPC sidecar), 24th platform (v0.17+).
    public var hasPhotonPlatform: Bool { atLeastSemver(0, 17, 0) }

    /// `whatsapp_cloud` gateway platform — WhatsApp Business Cloud API (Meta's
    /// hosted webhook path, distinct from the older `whatsapp` web bridge),
    /// 25th platform (v0.17+).
    public var hasWhatsAppCloudPlatform: Bool { atLeastSemver(0, 17, 0) }

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

    // MARK: v0.20 (v2026.8.3) flags

    /// ACP `/compact` was renamed `/compress` (v0.20+, v2026.8.3).
    public var hasCompressCommand: Bool { isV020OrLater }

    /// `hermes curator adopt` / `hermes curator list-unmanaged` — adopt
    /// stray notes into curator management and list unmanaged ones
    /// (v0.20+, v2026.8.3).
    public var hasCuratorAdopt: Bool { isV020OrLater }

    /// `hermes approvals suggest` — suggest an approval decision for a
    /// pending request (v0.20+, v2026.8.3).
    public var hasApprovalsSuggest: Bool { isV020OrLater }

    /// `hermes cron runs` — list past cron job runs (v0.20+, v2026.8.3).
    public var hasCronRuns: Bool { isV020OrLater }

    /// `hermes sessions export --format md|html|qmd|trace` — additional
    /// session export formats beyond the default (v0.20+, v2026.8.3).
    public var hasSessionsExportFormats: Bool { isV020OrLater }

    /// `approvals.smart_policy` — operator-customizable free-text policy
    /// appended to the smart-approval guardian's system prompt
    /// (hermes-agent commit bd1db5460a "feat(approvals): operator-
    /// customizable smart-approval policy", first released v2026.7.30 —
    /// between the v0.19.0 tag (v2026.7.20) and the v0.20.0 tag
    /// (v2026.8.3), so the next numbered floor this key is guaranteed
    /// present at is v0.20).
    public var hasApprovalSmartPolicy: Bool { isV020OrLater }

    /// `secrets.bitwarden.encrypted_cache.{enabled,max_stale_seconds}` —
    /// optional encrypted last-good Bitwarden fallback for network/timeout
    /// outages (v0.20+, hermes-agent commit 1384087729 "fix(secrets): add
    /// encrypted Bitwarden stale cache", first released v2026.7.30).
    public var hasBitwardenEncryptedCache: Bool { isV020OrLater }

    /// `secrets.command.*` — any-CLI vault helper secret source (v0.20+,
    /// hermes-agent commit 3d5dd8efa5 "feat(secrets): add `command` secret
    /// source + unified secrets.provider selector", first released
    /// v2026.7.30).
    public var hasCommandSecretSource: Bool { isV020OrLater }

    /// `telemetry.shared_metrics.enabled` — privacy-safe opt-in aggregate
    /// metrics written only to this profile's local telemetry directory,
    /// no remote sink (v0.20+, Relay pipeline commits 3bd338d2a9,
    /// 64faff6768, 056e7df0e0, 9baa8cc96c, 36185bf2e2, 43d994986e,
    /// 841a5a744a/14bed44c8c revert+reapply, all first released
    /// v2026.7.30).
    public var hasSharedMetricsTelemetry: Bool { isV020OrLater }

    /// `database.{journal_mode,wal_autocheckpoint,journal_size_limit}` —
    /// SQLite journal mode + WAL sizing pragmas applied by every Hermes
    /// database opener (v0.20+; `journal_mode` via commit 91351b7b7
    /// "fix(state): make journal mode canonical and behaviorally
    /// verified", `wal_autocheckpoint`/`journal_size_limit` via commit
    /// 9d4bfd5e3 "fix(config): register WAL sizing pragmas in
    /// DEFAULT_CONFIG" — both first released v2026.7.30).
    public var hasDatabaseJournalSettings: Bool { isV020OrLater }

    /// `stt.language` (global fallback hint, default `"en"`) +
    /// `stt.groq.{model,language}` — the unified STT language resolver
    /// (v0.20+, hermes-agent commit a10bd49ddd "feat(stt): unify language
    /// resolution across all STT providers" + commit bc997a36a8 "feat(stt):
    /// default global stt.language to 'en'", both first released
    /// v2026.7.30 — between the v0.19.0 tag (v2026.7.20) and the v0.20.0
    /// tag (v2026.8.3), so the next guaranteed floor is v0.20). Groq's STT
    /// provider itself predates this (env-var only); the commit is what
    /// makes `stt.groq.model`/`stt.groq.language` config-driven.
    public var hasSTTUnifiedLanguage: Bool { isV020OrLater }

    /// `stt.local.{vad,vad_min_silence_ms,no_speech_prob_threshold,
    /// logprob_threshold}` — faster-whisper anti-hallucination tuning
    /// (v0.20+, hermes-agent commit bf8004e3a8 "fix(stt): kill
    /// faster-whisper silence hallucinations at the source", first released
    /// v2026.7.30 — same window as `hasSTTUnifiedLanguage`, floor v0.20).
    public var hasSTTLocalVADTuning: Bool { isV020OrLater }

    /// `gateway.profile_routes` (and the top-level `profile_routes` form) —
    /// per-guild/channel/thread routing of inbound gateway messages to
    /// distinct Hermes profiles (hermes-agent commit 5e65f6d79f
    /// "feat(gateway): add profile-based routing for inbound messages",
    /// 2026-06-27). Unlike most of the v0.20 surface this one is genuinely
    /// older: the first tag containing it is v2026.7.20, whose
    /// `pyproject.toml` reads `version = "0.19.0"` (the preceding tag
    /// v2026.7.7.2 was 0.18.2), so the true floor is **v0.19**, not v0.20.
    public var hasGatewayProfileRoutes: Bool { isV019OrLater }

    // MARK: Convenience predicates

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

    /// Whether the connected host is on the v0.20 line or newer. Convenience
    /// for UI copy that toggles on the v0.19 → v0.20 boundary without
    /// proxying through a feature-specific flag.
    public var isV020OrLater: Bool { atLeastSemver(0, 20, 0) }

    private func atLeastSemver(_ major: Int, _ minor: Int, _ patch: Int) -> Bool {
        guard let s = semver else { return false }
        return s >= SemVer(major: major, minor: minor, patch: patch)
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

    /// Test hook: forget everything ``noteDetectedVersion(_:provisional:)``
    /// has reported, so a test can exercise the dedupe from a clean slate.
    static func resetReportedVersionsForTesting() {
        reportedVersions = []
    }

    /// Re-probe this host, bypassing the memoized result. Use after
    /// `hermes update` or when the user asks to re-detect.
    public func refresh() async {
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
            ScarfAnalytics.record("hermes_probe_failed", [
                "fallback": remembered.detected ? "last_known" : "empty",
            ])
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
