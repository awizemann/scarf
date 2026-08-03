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
            sttProvider: str("stt.provider", default: "local"),
            sttLocalModel: str("stt.local.model", default: "base"),
            sttLocalLanguage: str("stt.local.language"),
            sttOpenAIModel: str("stt.openai.model", default: "whisper-1"),
            sttMistralModel: str("stt.mistral.model", default: "voxtral-mini-latest"),
            ttsXAIVoiceID: str("tts.xai.voice_id"),
            ttsXAIModel: str("tts.xai.model"),
            // v0.15 round-trip — read the auto-speech-tags toggle back.
            ttsXAIAutoSpeechTags: bool("tts.xai.auto_speech_tags", default: false)
        )

        func aux(_ name: String) -> AuxiliaryModel {
            AuxiliaryModel(
                provider: str("auxiliary.\(name).provider", default: "auto"),
                model: str("auxiliary.\(name).model"),
                baseURL: str("auxiliary.\(name).base_url"),
                apiKey: str("auxiliary.\(name).api_key"),
                timeout: int("auxiliary.\(name).timeout", default: 30)
            )
        }
        let auxiliary = AuxiliarySettings(
            vision: aux("vision"),
            webExtract: aux("web_extract"),
            compression: aux("compression"),
            sessionSearch: aux("session_search"),
            skillsHub: aux("skills_hub"),
            approval: aux("approval"),
            mcp: aux("mcp"),
            flushMemories: aux("flush_memories"),
            curator: aux("curator")
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
            protectLastN: int("compression.protect_last_n", default: 20)
        )

        let checkpoints = CheckpointSettings(
            enabled: bool("checkpoints.enabled", default: true),
            maxSnapshots: int("checkpoints.max_snapshots", default: 50)
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
            maxIterations: int("delegation.max_iterations", default: 50)
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
            autoInstall: bool("secrets.bitwarden.auto_install", default: true)
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
        // `google_chat` is intentionally absent: its adapter gates access
        // via GOOGLE_CHAT_ALLOWED_USERS, never an allowed_channels list.
        let gatewayAllowlistPlatforms = [
            "slack", "mattermost",
            "telegram", "whatsapp",
            "matrix", "dingtalk",
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
            verbose: bool("agent.verbose", default: false),
            autoTTS: values["voice.auto_tts"] != "false",
            silenceThreshold: int("voice.silence_threshold", default: QueryDefaults.defaultSilenceThreshold),
            reasoningEffort: str("agent.reasoning_effort", default: "medium"),
            showCost: bool("display.show_cost", default: false),
            approvalMode: str("approvals.mode", default: "manual"),
            browserBackend: str("browser.backend"),
            memoryProvider: str("memory.provider"),
            dockerEnv: dockerEnv,
            commandAllowlist: commandAllowlist,
            memoryProfile: str("memory.profile"),
            serviceTier: str("agent.service_tier", default: "normal"),
            gatewayNotifyInterval: int("agent.gateway_notify_interval", default: 600),
            forceIPv4: bool("network.force_ipv4", default: false),
            contextEngine: str("context.engine", default: "compressor"),
            interimAssistantMessages: values["display.interim_assistant_messages"] != "false",
            honchoInitOnSessionStart: bool("honcho.initOnSessionStart", default: false),
            timezone: str("timezone"),
            userProfileEnabled: bool("memory.user_profile_enabled", default: true),
            toolUseEnforcement: str("agent.tool_use_enforcement", default: "auto"),
            gatewayTimeout: int("agent.gateway_timeout", default: 1800),
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
            redactionEnabled: bool("redaction.enabled", default: false),
            // Real Hermes key is `display.runtime_footer.enabled` (nested
            // block, config_defaults.py). `agent.runtime_metadata_footer`
            // never existed in Hermes but older Scarf builds wrote it —
            // read it as a fallback so those configs keep their setting;
            // writes go only to the new key.
            runtimeMetadataFooter: bool(
                "display.runtime_footer.enabled",
                default: bool("agent.runtime_metadata_footer", default: false)
            ),
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
            modelContextLength: str("model.context_length")
        )
    }
}
