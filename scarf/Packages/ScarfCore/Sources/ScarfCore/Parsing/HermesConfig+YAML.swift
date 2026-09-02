import Foundation

/// YAML-driven `HermesConfig` constructor. Lifted verbatim (with
/// trivial adjustments to access the ScarfCore-public types) from
/// `HermesFileService.parseConfig` so the same key → struct-field
/// mapping feeds both the Mac app and iOS.
///
/// **Behaviour parity.** Every default value, every key, and every
/// fallback path in this file tracks the Mac implementation
/// one-for-one. If the Mac parser learns to recognise a new key,
/// this one should too (and vice versa). The M6 test suite freezes
/// the defaults + a few recognition paths, so behaviour drift
/// surfaces on Linux CI without needing Xcode.
public extension HermesConfig {
    /// Parse a `config.yaml` string into a fully-populated
    /// `HermesConfig`. Missing keys fall back to `HermesConfig.empty`-
    /// compatible defaults. Unknown keys are ignored — Hermes is
    /// forward-compatible, i.e. a config file with newer keys than
    /// scarf knows still loads.
    ///
    /// The parse is deliberately forgiving: malformed YAML produces
    /// whatever partial state the parser could recover + defaults
    /// for everything else, not a throw. The iOS Settings view
    /// surfaces the raw file on top of this so users can spot a
    /// broken key even when the struct came back defaulted.
    init(yaml: String) {
        let parsed = HermesYAML.parseNestedYAML(yaml)
        let values = parsed.values
        let lists = parsed.lists
        let maps = parsed.maps

        func bool(_ key: String, default def: Bool) -> Bool {
            guard let v = values[key] else { return def }
            return v == "true"
        }
        func int(_ key: String, default def: Int) -> Int {
            Int(values[key] ?? "") ?? def
        }
        func double(_ key: String, default def: Double) -> Double {
            Double(values[key] ?? "") ?? def
        }
        func str(_ key: String, default def: String = "") -> String {
            let raw = values[key] ?? def
            return HermesYAML.stripYAMLQuotes(raw)
        }
        // True-optional int: `nil` means "key absent from config.yaml",
        // distinct from any concrete int including 0. Used for
        // `database.wal_autocheckpoint` / `database.journal_size_limit`,
        // where Hermes reads `database.get(key)` directly and treats an
        // absent key differently from `0` (see DatabaseSettings doc).
        func intOpt(_ key: String) -> Int? {
            guard let raw = values[key] else { return nil }
            return Int(raw)
        }
        // True-optional bool: `nil` means "key absent from config.yaml".
        // Used where the server-side default CHANGED across Hermes
        // releases (`checkpoints.enabled`, false since v0.21), so the
        // display layer resolves the absent case against the host's
        // capabilities instead of the parse baking in one release's
        // default. See `HermesConfig.displayCheckpointsEnabled`.
        func boolOpt(_ key: String) -> Bool? {
            guard let v = values[key] else { return nil }
            return v == "true"
        }

        let dockerEnv = maps["terminal.docker_env"] ?? [:]
        let commandAllowlist = lists["permanent_allowlist"] ?? lists["command_allowlist"] ?? []

        let display = DisplaySettings(
            skin: str("display.skin", default: "default"),
            compact: bool("display.compact", default: false),
            resumeDisplay: str("display.resume_display", default: "full"),
            bellOnComplete: bool("display.bell_on_complete", default: false),
            inlineDiffs: bool("display.inline_diffs", default: true),
            toolProgressCommand: bool("display.tool_progress_command", default: false),
            toolPreviewLength: int("display.tool_preview_length", default: 0),
            busyInputMode: str("display.busy_input_mode", default: "interrupt"),
            language: str("display.language"),
            timestamps: bool("display.timestamps", default: false)
        )

        let terminal = TerminalSettings(
            cwd: str("terminal.cwd", default: "."),
            timeout: int("terminal.timeout", default: 180),
            envPassthrough: lists["terminal.env_passthrough"] ?? [],
            persistentShell: bool("terminal.persistent_shell", default: true),
            dockerImage: str("terminal.docker_image"),
            dockerMountCwdToWorkspace: bool("terminal.docker_mount_cwd_to_workspace", default: false),
            dockerForwardEnv: lists["terminal.docker_forward_env"] ?? [],
            dockerVolumes: lists["terminal.docker_volumes"] ?? [],
            dockerExtraArgs: lists["terminal.docker_extra_args"] ?? [],
            containerCPU: int("terminal.container_cpu", default: 0),
            containerMemory: int("terminal.container_memory", default: 0),
            containerDisk: int("terminal.container_disk", default: 0),
            containerPersistent: bool("terminal.container_persistent", default: false),
            modalImage: str("terminal.modal_image"),
            modalMode: str("terminal.modal_mode", default: "auto"),
            daytonaImage: str("terminal.daytona_image"),
            singularityImage: str("terminal.singularity_image")
        )

        let browser = BrowserSettings(
            inactivityTimeout: int("browser.inactivity_timeout", default: 120),
            commandTimeout: int("browser.command_timeout", default: 30),
            recordSessions: bool("browser.record_sessions", default: false),
            allowPrivateURLs: bool("browser.allow_private_urls", default: false),
            camofoxManagedPersistence: bool("browser.camofox.managed_persistence", default: false)
        )

        let voice = VoiceSettings(
            recordKey: str("voice.record_key", default: "ctrl+b"),
            maxRecordingSeconds: int("voice.max_recording_seconds", default: 120),
            silenceDuration: double("voice.silence_duration", default: 3.0),
            ttsProvider: str("tts.provider", default: "edge"),
            ttsEdgeVoice: str("tts.edge.voice", default: "en-US-AriaNeural"),
            ttsElevenLabsVoiceID: str("tts.elevenlabs.voice_id"),
            ttsElevenLabsModelID: str("tts.elevenlabs.model_id", default: "eleven_multilingual_v2"),
            ttsOpenAIModel: str("tts.openai.model", default: "gpt-4o-mini-tts"),
            ttsOpenAIVoice: str("tts.openai.voice", default: "alloy"),
            ttsNeuTTSModel: str("tts.neutts.model"),
            ttsNeuTTSDevice: str("tts.neutts.device", default: "cpu"),
            sttEnabled: bool("stt.enabled", default: true),
            // Empty means the key is absent. Hermes v0.20.5 stopped seeding
            // `stt.provider` in config_defaults.py, so an absent key is the
            // autodetect ladder rather than `local`; defaulting to "local"
            // here would render an unset key as a pin. Older hosts seeded
            // `local`, which the picker surfaces via its "Auto" label — see
            // `SettingsViewModel.sttProviders`.
            sttProvider: str("stt.provider"),
            sttLocalModel: str("stt.local.model", default: "base"),
            sttLocalLanguage: str("stt.local.language"),
            sttOpenAIModel: str("stt.openai.model", default: "whisper-1"),
            sttMistralModel: str("stt.mistral.model", default: "voxtral-mini-latest"),
            ttsXAIVoiceID: str("tts.xai.voice_id"),
            // v0.15 round-trip — read the auto-speech-tags toggle back.
            ttsXAIAutoSpeechTags: bool("tts.xai.auto_speech_tags", default: false),
            // v0.19 round-trip (hasXAITTSAdvancedParams) — read back even on
            // pre-v0.19 hosts where the keys are simply absent (defaults win).
            ttsXAILanguage: str("tts.xai.language", default: "en"),
            ttsXAISpeed: double("tts.xai.speed", default: 1.0),
            ttsXAIOptimizeStreamingLatency: int("tts.xai.optimize_streaming_latency", default: 0),
            ttsXAISampleRate: int("tts.xai.sample_rate", default: 24000),
            ttsXAIBitRate: int("tts.xai.bit_rate", default: 128000),
            // v0.19 round-trip (hasDeepInfraTTS).
            ttsDeepInfraModel: str("tts.deepinfra.model"),
            ttsDeepInfraVoice: str("tts.deepinfra.voice", default: "default"),
            // Predates version tracking, like sttOpenAIModel; ungated.
            sttOpenAILanguage: str("stt.openai.language"),
            // v0.20 round-trip (hasSTTUnifiedLanguage).
            sttLanguage: str("stt.language", default: "en"),
            sttGroqModel: str("stt.groq.model", default: "whisper-large-v3-turbo"),
            sttGroqLanguage: str("stt.groq.language"),
            // v0.20 round-trip (hasSTTLocalVADTuning).
            sttLocalVAD: bool("stt.local.vad", default: true),
            sttLocalVADMinSilenceMS: int("stt.local.vad_min_silence_ms", default: 500),
            sttLocalNoSpeechProbThreshold: double("stt.local.no_speech_prob_threshold", default: 0.6),
            sttLocalLogprobThreshold: double("stt.local.logprob_threshold", default: -1.0),
            // v0.20.4 round-trip.
            sttLocalUnloadAfterIdleSeconds: int("stt.local.unload_after_idle_seconds", default: 0),
            // Top-level `stt.cloud_trim_*` — siblings of `stt.local.*`, NOT
            // nested under it.
            sttCloudTrimSilence: bool("stt.cloud_trim_silence", default: true),
            sttCloudTrimThresholdDB: double("stt.cloud_trim_threshold_db", default: -40),
            sttCloudTrimKeepMS: int("stt.cloud_trim_keep_ms", default: 300),
            wakeWordCapture: str("wake_word.capture", default: "auto")
        )

        func aux(_ name: String) -> AuxiliaryModel {
            AuxiliaryModel(
                provider: str("auxiliary.\(name).provider", default: "auto"),
                model: str("auxiliary.\(name).model"),
                baseURL: str("auxiliary.\(name).base_url"),
                apiKey: str("auxiliary.\(name).api_key"),
                timeout: int("auxiliary.\(name).timeout", default: 30),
                // `auxiliary.<task>.reasoning_effort` — v0.19+
                // (hermes-agent commit df5700ebe3, first released
                // v2026.7.20 = v0.19.0). Empty = provider default.
                reasoningEffort: str("auxiliary.\(name).reasoning_effort"),
                // v0.20.4+ true-optional cap (documented for `compression`;
                // harmless to read for every task via the shared `aux` helper).
                maxConcurrency: intOpt("auxiliary.\(name).max_concurrency")
            )
        }
        let titleGeneration = TitleGenerationSettings(
            enabled: bool("auxiliary.title_generation.enabled", default: true),
            provider: str("auxiliary.title_generation.provider", default: "auto"),
            model: str("auxiliary.title_generation.model"),
            baseURL: str("auxiliary.title_generation.base_url"),
            apiKey: str("auxiliary.title_generation.api_key"),
            timeout: int("auxiliary.title_generation.timeout", default: 30),
            reasoningEffort: str("auxiliary.title_generation.reasoning_effort"),
            language: str("auxiliary.title_generation.language"),
            // v0.20.4+ true-optional cap on simultaneous title calls.
            maxConcurrency: intOpt("auxiliary.title_generation.max_concurrency")
        )
        let auxiliary = AuxiliarySettings(
            vision: aux("vision"),
            // Parsed unconditionally on purpose. The `auxiliary.web_extract.*`
            // block was deleted upstream at v2026.8.27 (0.20.6) — newer hosts
            // ignore any leftover values — but pre-v0.20.6 hosts still read
            // it, and the Auxiliary tab still renders the editor there
            // (`hasWebExtractAux`). Dropping the parse would blank that row's
            // real values on exactly the hosts that need them.
            webExtract: aux("web_extract"),
            compression: aux("compression"),
            sessionSearch: aux("session_search"),
            skillsHub: aux("skills_hub"),
            approval: aux("approval"),
            mcp: aux("mcp"),
            flushMemories: aux("flush_memories"),
            curator: aux("curator"),
            titleGeneration: titleGeneration,
            // v0.20.4+ — NOT `agent.background_review.enabled`; nested under
            // the top-level `auxiliary:` block (source-verified).
            backgroundReviewEnabled: bool("auxiliary.background_review.enabled", default: true)
        )

        let security = SecuritySettings(
            redactSecrets: bool("security.redact_secrets", default: true),
            redactPII: bool("privacy.redact_pii", default: false),
            tirithEnabled: bool("security.tirith_enabled", default: true),
            tirithPath: str("security.tirith_path", default: "tirith"),
            tirithTimeout: int("security.tirith_timeout", default: 5),
            tirithFailOpen: bool("security.tirith_fail_open", default: true),
            blocklistEnabled: bool("security.website_blocklist.enabled", default: false),
            blocklistDomains: lists["security.website_blocklist.domains"] ?? []
        )

        let humanDelay = HumanDelaySettings(
            mode: str("human_delay.mode", default: "off"),
            minMS: int("human_delay.min_ms", default: 800),
            maxMS: int("human_delay.max_ms", default: 2500)
        )

        let compression = CompressionSettings(
            enabled: bool("compression.enabled", default: true),
            threshold: double("compression.threshold", default: 0.5),
            targetRatio: double("compression.target_ratio", default: 0.2),
            protectLastN: int("compression.protect_last_n", default: 20),
            // -- v0.20 tuning keys. `threshold_tokens` defaults to `None`
            // in Hermes (config_defaults.py:577); 0 is Scarf's "absent"
            // sentinel and Hermes treats <= 0 as off, so the round-trip is
            // lossless either way.
            thresholdTokens: int("compression.threshold_tokens", default: 0),
            minTailUserMessages: int("compression.min_tail_user_messages", default: 1),
            idleCompactAfterSeconds: int("compression.idle_compact_after_seconds", default: 0),
            progressNotices: bool("compression.progress_notices", default: false)
        )

        // Sentinels, not defaults: v0.21 flipped both server-side defaults
        // (enabled true→false, max_snapshots 50→20), so an absent key must
        // resolve against the host — `HermesConfig.displayCheckpoints*`.
        let checkpoints = CheckpointSettings(
            enabled: boolOpt("checkpoints.enabled"),
            maxSnapshots: int("checkpoints.max_snapshots", default: 0)
        )

        let logging = LoggingSettings(
            level: str("logging.level", default: "INFO"),
            maxSizeMB: int("logging.max_size_mb", default: 5),
            backupCount: int("logging.backup_count", default: 3)
        )

        let delegation = DelegationSettings(
            model: str("delegation.model"),
            provider: str("delegation.provider"),
            baseURL: str("delegation.base_url"),
            apiKey: str("delegation.api_key"),
            // Sentinel 0 = absent; the v0.20.4 migrations raised both
            // defaults (50→250, 3→10), so resolve via
            // `HermesConfig.displayDelegationMax*`.
            maxIterations: int("delegation.max_iterations", default: 0),
            maxConcurrentChildren: int("delegation.max_concurrent_children", default: 0)
        )

        let discord = DiscordSettings(
            requireMention: bool("discord.require_mention", default: true),
            freeResponseChannels: str("discord.free_response_channels"),
            autoThread: bool("discord.auto_thread", default: true),
            reactions: bool("discord.reactions", default: true),
            historyBackfill: bool("discord.history_backfill", default: true),
            allowAnyAttachment: bool("platforms.discord.extra.allow_any_attachment", default: false)
        )

        let telegram = TelegramSettings(
            requireMention: bool("telegram.require_mention", default: true),
            reactions: bool("telegram.reactions", default: false),
            disableTopicAutoRename: bool("telegram.disable_topic_auto_rename", default: false),
            ignoreRootDM: bool("platforms.telegram.extra.ignore_root_dm", default: false),
            richMessages: bool("platforms.telegram.extra.rich_messages", default: true),
            statusIndicator: bool("platforms.telegram.extra.status_indicator", default: false)
        )

        // -- v0.15: Signal group-only require_mention + ntfy (23rd platform).
        let signal = SignalSettings(
            requireMention: bool("platforms.signal.extra.require_mention", default: false)
        )

        let ntfy = NtfySettings(
            topic: str("platforms.ntfy.extra.topic"),
            server: str("platforms.ntfy.extra.server", default: "https://ntfy.sh"),
            publishTopic: str("platforms.ntfy.extra.publish_topic"),
            token: str("platforms.ntfy.extra.token"),
            markdown: bool("platforms.ntfy.extra.markdown", default: false)
        )

        // -- v0.17: WhatsApp Business Cloud API (`platforms.whatsapp_cloud.extra.*`).
        // Meta's hosted webhook path; creds + verify/app secrets live in the YAML
        // extra block (not .env). dm_policy gates DMs (allowlist activates allow_from).
        let whatsappCloud = WhatsAppCloudSettings(
            phoneNumberID: str("platforms.whatsapp_cloud.extra.phone_number_id"),
            accessToken: str("platforms.whatsapp_cloud.extra.access_token"),
            verifyToken: str("platforms.whatsapp_cloud.extra.verify_token"),
            appSecret: str("platforms.whatsapp_cloud.extra.app_secret"),
            appID: str("platforms.whatsapp_cloud.extra.app_id"),
            wabaID: str("platforms.whatsapp_cloud.extra.waba_id"),
            apiVersion: str("platforms.whatsapp_cloud.extra.api_version", default: "v20.0"),
            dmPolicy: str("platforms.whatsapp_cloud.extra.dm_policy", default: "open"),
            allowFrom: str("platforms.whatsapp_cloud.extra.allow_from")
        )

        // -- v0.15: Bitwarden Secrets Manager bootstrap (`secrets.bitwarden.*`).
        // The access token VALUE lives in `~/.hermes/.env` under the env var
        // named here; only its NAME (+ the routing knobs) round-trips through
        // config.yaml. Every field is read back so the Secrets tab persists.
        let bitwarden = BitwardenSettings(
            enabled: bool("secrets.bitwarden.enabled", default: false),
            accessTokenEnv: str("secrets.bitwarden.access_token_env", default: "BWS_ACCESS_TOKEN"),
            projectID: str("secrets.bitwarden.project_id"),
            overrideExisting: bool("secrets.bitwarden.override_existing", default: false),
            serverURL: str("secrets.bitwarden.server_url"),
            cacheTTLSeconds: int("secrets.bitwarden.cache_ttl_seconds", default: 300),
            autoInstall: bool("secrets.bitwarden.auto_install", default: true),
            // `secrets.bitwarden.encrypted_cache` — v0.20+ (commit
            // 1384087729, first released v2026.7.30). `max_stale_seconds`
            // defaults to 0 ("no stale fallback"), a real value distinct
            // from unset.
            encryptedCache: BitwardenEncryptedCacheSettings(
                enabled: bool("secrets.bitwarden.encrypted_cache.enabled", default: false),
                maxStaleSeconds: int("secrets.bitwarden.encrypted_cache.max_stale_seconds", default: 0)
            )
        )

        // `secrets.command.*` — v0.20+ any-CLI vault helper secret source
        // (commit 3d5dd8efa5, first released v2026.7.30). See
        // `CommandSecretsSettings` for the trust-model note on `command`.
        let commandSecrets = CommandSecretsSettings(
            enabled: bool("secrets.command.enabled", default: false),
            command: str("secrets.command.command"),
            helperTimeoutSeconds: double("secrets.command.helper_timeout_seconds", default: 3.0),
            overrideExisting: bool("secrets.command.override_existing", default: false)
        )

        // `telemetry.shared_metrics` — v0.20+ opt-in local aggregate
        // metrics (Relay pipeline, first released v2026.7.30).
        let telemetry = TelemetrySettings(
            sharedMetricsEnabled: bool("telemetry.shared_metrics.enabled", default: false)
        )

        // `database.*` — SQLite journal/WAL sizing pragmas, v0.20+ (first
        // released v2026.7.30). `wal_autocheckpoint` / `journal_size_limit`
        // are true optionals: absent key != 0.
        let database = DatabaseSettings(
            journalMode: str("database.journal_mode", default: "wal"),
            walAutocheckpoint: intOpt("database.wal_autocheckpoint"),
            journalSizeLimit: intOpt("database.journal_size_limit")
        )

        // Slack fields live under both `platforms.slack.*` (newer) and `slack.*`
        // (legacy). Prefer the newer path but fall back.
        let slack = SlackSettings(
            replyToMode: values["platforms.slack.reply_to_mode"] ?? values["slack.reply_to_mode"] ?? "first",
            requireMention: (values["platforms.slack.require_mention"] ?? values["slack.require_mention"]) != "false",
            replyInThread: (values["platforms.slack.extra.reply_in_thread"] ?? "true") != "false",
            replyBroadcast: (values["platforms.slack.extra.reply_broadcast"] ?? "false") == "true"
        )

        let matrix = MatrixSettings(
            requireMention: bool("matrix.require_mention", default: true),
            autoThread: bool("matrix.auto_thread", default: true),
            dmMentionThreads: bool("matrix.dm_mention_threads", default: false)
        )

        let mattermost = MattermostSettings(
            requireMention: bool("mattermost.require_mention", default: true),
            replyMode: str("mattermost.reply_mode", default: "off")
        )

        let whatsapp = WhatsAppSettings(
            unauthorizedDMBehavior: str("whatsapp.unauthorized_dm_behavior", default: "pair"),
            replyPrefix: str("whatsapp.reply_prefix")
        )

        // `platform_toolsets.<platform>` is a dict of lists in config.yaml —
        // parseNestedYAML flattens nested lists into dotted-path keys. Pull
        // every key under the prefix and strip it.
        var platformToolsets: [String: [String]] = [:]
        for (key, items) in lists where key.hasPrefix("platform_toolsets.") {
            let platform = String(key.dropFirst("platform_toolsets.".count))
            guard !platform.isEmpty else { continue }
            platformToolsets[platform] = items
        }

        // Home Assistant lives under `platforms.homeassistant.extra.*`.
        let homeAssistant = HomeAssistantSettings(
            watchDomains: lists["platforms.homeassistant.extra.watch_domains"] ?? [],
            watchEntities: lists["platforms.homeassistant.extra.watch_entities"] ?? [],
            watchAll: bool("platforms.homeassistant.extra.watch_all", default: false),
            ignoreEntities: lists["platforms.homeassistant.extra.ignore_entities"] ?? [],
            cooldownSeconds: int("platforms.homeassistant.extra.cooldown_seconds", default: 30)
        )

        // -- v0.13: per-platform Messaging Gateway settings --------------
        // Allowlists live at top-level `<platform>.allowed_*` (verified
        // v0.16): `slack.allowed_channels`, `telegram.allowed_chats`,
        // `matrix.allowed_rooms`, `dingtalk.allowed_chats`, plus the
        // top-level `<platform>.gateway_restart_notification` toggle.
        // `busy_ack_enabled` / `slash_command_notice_ttl_seconds` are
        // no-ops in v0.16 but kept for round-trip. Platforms without an
        // explicit block don't appear in the dictionary, so the editor's
        // `?? .empty` fallback hands the user the defaults without leaving
        // stale keys littered across the YAML.
        // `google_chat` has no allowlist (its adapter gates access via
        // GOOGLE_CHAT_ALLOWED_USERS, never an allowed_channels list) but it
        // DOES get a `GatewayBehaviorSection`, so Scarf writes its
        // `google_chat.gateway_restart_notification`. Leaving it out of this
        // loop made that toggle a write-only key: it saved, then the next
        // load read `false` and the switch snapped back. The allowlists
        // simply come back empty for it.
        let gatewayAllowlistPlatforms = [
            "slack", "mattermost",
            "telegram", "whatsapp",
            "matrix", "dingtalk",
            "google_chat",
        ]
        var gatewayPlatforms: [String: GatewayPlatformSettings] = [:]
        for platform in gatewayAllowlistPlatforms {
            let prefix = "\(platform)."
            let allowedChannels = lists[prefix + "allowed_channels"] ?? []
            let allowedChats    = lists[prefix + "allowed_chats"]    ?? []
            let allowedRooms    = lists[prefix + "allowed_rooms"]    ?? []
            let busy            = bool(prefix + "busy_ack_enabled", default: true)
            let restartNotice   = bool(prefix + "gateway_restart_notification",
                                       default: false)
            let ttl             = int(prefix + "slash_command_notice_ttl_seconds",
                                      default: 0)
            // Skip platforms with no v0.13 fields present anywhere in the
            // file. Without this guard, every supported platform would
            // round-trip an all-default block back through writes even
            // when the user never touched the new surface.
            let isEmpty = allowedChannels.isEmpty
                && allowedChats.isEmpty
                && allowedRooms.isEmpty
                && values[prefix + "busy_ack_enabled"] == nil
                && values[prefix + "gateway_restart_notification"] == nil
                && values[prefix + "slash_command_notice_ttl_seconds"] == nil
            if !isEmpty {
                gatewayPlatforms[platform] = GatewayPlatformSettings(
                    allowedChannels: allowedChannels,
                    allowedChats: allowedChats,
                    allowedRooms: allowedRooms,
                    busyAckEnabled: busy,
                    gatewayRestartNotification: restartNotice,
                    slashCommandNoticeTTLSeconds: ttl
                )
            }
        }

        self.init(
            model: str("model.default", default: "unknown"),
            provider: str("model.provider", default: "unknown"),
            // 0 is the "key absent" sentinel, NOT a real default. Hermes's
            // server-side default changed at v0.20 (60 → 500), so parsing a
            // concrete number here would bake one host generation's default
            // into configs read from the other. Display surfaces resolve the
            // sentinel via `displayMaxTurns(capabilities:)`; nothing writes
            // the resolved value back unless the user edits it.
            maxTurns: int("agent.max_turns", default: 0),
            personality: str("display.personality", default: "default"),
            terminalBackend: str("terminal.backend", default: "local"),
            memoryEnabled: bool("memory.memory_enabled", default: false),
            memoryCharLimit: int("memory.memory_char_limit", default: 0),
            userCharLimit: int("memory.user_char_limit", default: 0),
            nudgeInterval: int("memory.nudge_interval", default: 0),
            streaming: values["display.streaming"] != "false",
            showReasoning: bool("display.show_reasoning", default: false),
            autoTTS: values["voice.auto_tts"] != "false",
            silenceThreshold: int("voice.silence_threshold", default: QueryDefaults.defaultSilenceThreshold),
            reasoningEffort: str("agent.reasoning_effort", default: "medium"),
            showCost: bool("display.show_cost", default: false),
            approvalMode: str("approvals.mode", default: "manual"),
            browserCloudProvider: str("browser.cloud_provider"),
            memoryProvider: str("memory.provider"),
            dockerEnv: dockerEnv,
            commandAllowlist: commandAllowlist,
            memoryProfile: str("memory.profile"),
            serviceTier: str("agent.service_tier", default: "normal"),
            gatewayNotifyInterval: int("agent.gateway_notify_interval", default: 600),
            forceIPv4: bool("network.force_ipv4", default: false),
            contextEngine: str("context.engine", default: "compressor"),
            // Absent → `true`, matching the Hermes schema default that runtime
            // merging supplies. Deliberately NOT inferred from absence: the
            // v14→15 migration that used to materialise
            // `display.interim_assistant_messages: true` on disk was DELETED
            // from the migration registry at v2026.8.27 (0.20.6) precisely
            // because "v15 only added a schema default; runtime merging
            // supplies it without a write. Registering a migration would
            // falsely report or materialise it." So on v0.20.6+ hosts an
            // absent key is the normal, expected state and must still read as
            // enabled. Only an explicit `false` turns it off.
            interimAssistantMessages: values["display.interim_assistant_messages"] != "false",
            honchoInitOnSessionStart: bool("honcho.initOnSessionStart", default: false),
            timezone: str("timezone"),
            userProfileEnabled: bool("memory.user_profile_enabled", default: true),
            toolUseEnforcement: str("agent.tool_use_enforcement", default: "auto"),
            gatewayTimeout: int("agent.gateway_timeout", default: 1800),
            cronDrainTimeout: int("agent.cron_drain_timeout", default: 30),
            // 0 is the "key absent" sentinel, NOT a real default — the
            // upstream default changed at v0.21.0 (1800 → 5). Display
            // surfaces resolve it via
            // `displayGatewayTurnLeaseTimeout(capabilities:)`.
            gatewayTurnLeaseTimeout: int("agent.gateway_turn_lease_timeout", default: 0),
            approvalTimeout: int("approvals.timeout", default: 60),
            fileReadMaxChars: int("file_read_max_chars", default: 100_000),
            cronWrapResponse: bool("cron.wrap_response", default: true),
            curatorConsolidate: bool("curator.consolidate", default: false),
            maxConcurrentSessions: int("max_concurrent_sessions", default: 0),
            prefillMessagesFile: str("prefill_messages_file"),
            skillsExternalDirs: lists["skills.external_dirs"] ?? [],
            platformToolsets: platformToolsets,
            display: display,
            terminal: terminal,
            browser: browser,
            voice: voice,
            auxiliary: auxiliary,
            security: security,
            humanDelay: humanDelay,
            compression: compression,
            checkpoints: checkpoints,
            logging: logging,
            delegation: delegation,
            discord: discord,
            telegram: telegram,
            slack: slack,
            matrix: matrix,
            mattermost: mattermost,
            whatsapp: whatsapp,
            homeAssistant: homeAssistant,
            cacheTTL: str("prompt_caching.cache_ttl", default: "5m"),
            // `display.runtime_footer.enabled` (nested block,
            // config_defaults.py) is the only key Hermes has ever read for
            // this. A fallback read of `agent.runtime_metadata_footer` used
            // to sit here; that key exists in NO supported Hermes version
            // (only some long-obsolete Scarf build ever wrote it), so it was
            // removed rather than carried forward.
            runtimeMetadataFooter: bool("display.runtime_footer.enabled", default: false),
            displayBusyAckEnabled: bool("display.busy_ack_enabled", default: true),
            gatewayPlatforms: gatewayPlatforms,
            // -- v0.13 additions -------------------------------------
            // Hermes v0.16: `openrouter.response_cache` is a SCALAR bool
            // directly under `openrouter:` (default `true` in Hermes).
            // Read it as the scalar. A legacy nested value
            // (`openrouter.response_cache.enabled: …`) flattens to a
            // different dotted key, so it has no scalar entry here and
            // decodes to the default `false` — the next save writes the
            // scalar, healing the shape. Keep in lockstep with the
            // matching `setSetting` key in
            // `SettingsViewModel.setOpenRouterResponseCache`.
            imageGenModel: str("image_gen.model", default: ""),
            openrouterResponseCacheEnabled: bool("openrouter.response_cache", default: false),
            // Hermes reads the `web:` block: `web.backend` is the shared
            // fallback (all supported hosts), `web.search_backend` /
            // `web.extract_backend` are v0.13+ per-capability overrides
            // ("" = inherit the shared fallback — Hermes semantics; the
            // WebTools tab chooses rows via `hasWebToolsBackendSplit`).
            // Scarf read `web_tools.*` until the v0.18 audit — dead keys
            // Hermes never wrote, so the tab always showed defaults.
            webToolsBackend: str("web.backend", default: ""),
            webToolsSearchBackend: str("web.search_backend", default: ""),
            webToolsExtractBackend: str("web.extract_backend", default: ""),
            // -- v0.15 additions -------------------------------------
            ntfy: ntfy,
            whatsappCloud: whatsappCloud,
            signal: signal,
            bitwarden: bitwarden,
            // Local/custom-endpoint trio — read back so the model
            // picker's Local tab round-trips an existing local setup.
            modelBaseURL: str("model.base_url"),
            modelAPIKey: str("model.api_key"),
            modelAPIMode: str("model.api_mode"),
            modelContextLength: str("model.context_length"),
            // -- v0.20 additions -------------------------------------
            // `agent.reasoning_overrides` is a nested map — parseNestedYAML
            // records `key: value` children under the parent's dotted path.
            // Keys arrive unquoted (HermesYAML strips a quoting layer) so
            // `'llama3:8b': high` reads back as `llama3:8b`.
            reasoningOverrides: maps["agent.reasoning_overrides"] ?? [:],
            excludedProviders: lists["model_catalog.excluded_providers"] ?? [],
            // `approvals.smart_policy` (v0.20+, config_defaults.py:2053) —
            // free-form policy text for the smart-approval guardian.
            approvalSmartPolicy: str("approvals.smart_policy"),
            // -- P3b additions (v0.20+, all first released v2026.7.30) --
            commandSecrets: commandSecrets,
            telemetry: telemetry,
            database: database,
            // `profile_routes` is a list of MAPS — the one shape
            // parseNestedYAML doesn't model — so it gets its own scanner,
            // which also reports which of the two accepted forms Hermes
            // would actually read (v0.19+, gateway/profile_routing.py).
            profileRoutes: ProfileRoutesYAML.parse(yaml),
            // `multiplex_profile_allowlist` (v0.20.4+) — true-optional list.
            // A top-level key takes PRECEDENCE over `gateway.*` (gateway/
            // config.py:1190-1195, 1413-1423) — mirrors the top-level-wins
            // pattern `ProfileRoutesYAML.parse` uses for `multiplex_profiles`.
            // `nil` = key absent from config.yaml at either spelling
            // (serve-all). A malformed value — present as a scalar, or as a
            // mapping (a section header with children but no bullet list) —
            // is normalized to `[]`, matching upstream's fail-safe of
            // serving only the "default" profile, rather than failing open
            // (nil → serve-all) or being silently dropped.
            multiplexProfileAllowlist: Self.multiplexProfileAllowlist(
                values: values, lists: lists, maps: maps
            )
        )
    }

    /// Resolve `multiplex_profile_allowlist` from the three `ParsedYAML`
    /// dictionaries, checking the top-level spelling before falling back to
    /// `gateway.*` (see the call site's doc comment for the precedence +
    /// fail-closed rationale).
    private static func multiplexProfileAllowlist(
        values: [String: String], lists: [String: [String]], maps: [String: [String: String]]
    ) -> [String]? {
        func resolve(_ key: String) -> [String]? {
            if let list = lists[key] { return list }
            if values[key] != nil { return [] }
            // A mapping-valued key (section header with `key: value`
            // children but no bullet list) fails CLOSED to `[]` — Hermes
            // restricts to the default profile rather than serving all.
            if maps[key]?.isEmpty == false { return [] }
            return nil
        }
        if let resolved = resolve("multiplex_profile_allowlist") { return resolved }
        if let resolved = resolve("gateway.multiplex_profile_allowlist") { return resolved }
        return nil
    }
}
