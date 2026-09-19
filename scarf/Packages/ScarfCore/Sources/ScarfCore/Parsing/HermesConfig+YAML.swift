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

        // Every typed reader below compares a NORMALISED scalar: the raw
        // parse keeps everything after `key: ` verbatim, so `false  # off`
        // and `"false"` are both legal YAML for `false` that no literal
        // comparison would ever match. See `HermesYAML.normalizedScalar`.
        func scalar(_ key: String) -> String? {
            values[key].map(HermesYAML.normalizedScalar)
        }
        // There is deliberately NO literal `== "true"` bool reader here any
        // more. config.yaml is read by PyYAML, so `yes` / `on` / `no` / `off`
        // are already Python bools by the time ANY Hermes reader sees them and
        // `1` / `0` are truthy/falsy ints — the coercion happens in the LOADER,
        // not in the per-key reader, so it applies to every boolean key
        // regardless of which module reads it. A literal comparison therefore
        // rendered `compact: yes` (and 38 other keys) as OFF while the host had
        // it ON. Every boolean key goes through `boolish` / `boolTrueDefault` /
        // `boolishOpt`; the only thing a key still chooses is its DEFAULT.
        // TRUE-by-default key: absent means the host is doing the thing, and
        // only an explicit falsy scalar turns it off. `bool(_:default: true)`
        // would be wrong here — it reads any spelling other than the literal
        // `true` (a hand-edited `no`, `off`, `0`, or a capitalised `False`)
        // as "on", which is the opposite of what the host does. The falsy
        // set mirrors Hermes's own reader for the one key whose default
        // lives in code rather than `config_defaults.py`
        // (`agent/agent_init.py`: `_streaming in {"false", "0", "no", "off"}`);
        // for the YAML-boolean keys it is a superset of what PyYAML would
        // have turned into `False` anyway.
        //
        // P57: the falsy test runs on the scalar STRIPPED inside its quotes
        // and on PyYAML's int resolver, because that is what Hermes compares
        // — `_bool_token` is `str(value).strip().lower()`
        // (`gateway/config.py:29-32` @ `v2026.9.7`). A verbatim body compare
        // read `" false"`, `"\tno\t"`, `00`, `-0`, `0x0` and `0b0` as
        // unrecognised and therefore ON, for keys whose host had them OFF —
        // the unsafe direction for a true-by-default key.
        func boolTrueDefault(_ key: String) -> Bool {
            guard let raw = values[key] else { return true }
            return HermesYAML.boolishValue(raw) != false
        }
        // Raw scalar for a `_SHARED_KEYS` member of a gateway platform,
        // resolved with Hermes's OWN precedence rather than a key list ordered
        // by guesswork. `gateway/config_loader.py` @ v2026.9.7 decides it in
        // two steps:
        //
        //  1. `platform_section` (:171-180) picks ONE section to bridge from —
        //     "a top-level `<name>:` block wins; otherwise the block under
        //     `gateway.platforms` / `platforms`". A top-level block therefore
        //     does not merely out-rank the nested one key-by-key: it REPLACES
        //     it as the bridge source, so with `slack:` present at the top
        //     level a `platforms.slack.require_mention` is never bridged and
        //     never reaches the adapter at all.
        //  2. `bridge_platform_shared_keys` (:249-283) copies the chosen
        //     section's shared keys into the platform's `extra` with
        //     `extra.update(bridged)` (:283) — so a bridged value OVERWRITES
        //     whatever `merge_platform_sections` (:136-147) had already merged
        //     into `extra` from the `extra:` sub-keys, and within that merge
        //     `platforms.<p>.extra` wins over `gateway.platforms.<p>.extra`.
        //
        // Hence: bridge source first, then the two `extra:` spellings. A
        // top-level block is detected as Hermes detects it — `isinstance(…,
        // dict)`, i.e. the block has at least one child (a bare `slack:` with
        // no children is `None` to PyYAML and is NOT a dict, which is exactly
        // what "no `slack.*` key in the flat parse" means here).
        func sharedPlatformScalar(_ plat: String, _ key: String) -> String? {
            func raw(_ section: String) -> String? {
                // `maps[section]` covers the inline flow form
                // (`slack: {require_mention: false}`), which the flat parse
                // keeps as a map rather than dotted keys.
                values["\(section).\(key)"] ?? maps[section]?[key]
            }
            // Step 1 lives in `HermesPlatformSharedKeys` since P44, because
            // the WRITE side needs the same answer (`t-6fa3fc84`) and a
            // second copy of `platform_section` is how the two halves got
            // out of phase in the first place.
            let bridgeSource = HermesPlatformSharedKeys.bridgeSourcePrefix(
                platform: plat,
                in: parsed
            )
            return raw(bridgeSource)
                ?? raw("platforms.\(plat).extra")
                ?? raw("gateway.platforms.\(plat).extra")
        }
        /// A `_SHARED_KEYS` boolean with a TRUE host default, read through
        /// `sharedPlatformScalar`'s precedence and Hermes's boolish sets.
        ///
        /// NOT for `mattermost.require_mention` — that key's reader has its
        /// own three-word falsy set (see `mattermostRequireMention` below).
        func sharedPlatformBool(_ plat: String, _ key: String, default def: Bool) -> Bool {
            HermesYAML.boolishValue(sharedPlatformScalar(plat, key)) ?? def
        }
        /// `mattermost.require_mention`, which reaches its comparison as a
        /// `str()` of whatever PyYAML loaded rather than as a boolish scalar
        /// — so `"OFF"` (quoted) is TRUE and bare `off` is false, and
        /// `boolishValue` is wrong on both. The rule and its citation live in
        /// ``HermesYAML/mattermostRequireMention(configScalar:)``; the
        /// precedence (the bridged section, not the flat spelling) is
        /// `sharedPlatformScalar`'s, unchanged.
        func mattermostRequireMention(default def: Bool) -> Bool {
            HermesYAML.mattermostRequireMention(
                configScalar: sharedPlatformScalar("mattermost", "require_mention")) ?? def
        }
        // `display.busy_ack_enabled` and `mattermost.require_mention` are the
        // TWO boolean keys in config.yaml whose effective vocabulary is NOT
        // the universal boolish set, each for its own reason. This one
        // reaches its reader through an env bridge that stringifies:
        //
        //   gateway/run.py:1813  `_DISPLAY_ENV_BRIDGE` maps it to
        //                        HERMES_GATEWAY_BUSY_ACK_ENABLED
        //   gateway/run.py:1818  `os.environ[env_var] = str(section[cfg_key])`
        //   gateway/run_busy.py:727
        //     `if os.environ.get(..., "true").lower() != "true": return True`
        //                        (i.e. anything but the word "true" DISABLES)
        //
        // PyYAML has already turned the YAML scalar into a Python object, so
        // `str()` sees `True`/`False`/`1`/`0`. `true`/`yes`/`on` all load as
        // `True` → `"true"` → ack ENABLED; but `1` loads as the INT 1 →
        // `str(1)` = `"1"` ≠ `"true"` → ack DISABLED, even though every other
        // boolean key in the file reads `1` as on. `boolTrueDefault` therefore
        // reported the ack ON for a host that had suppressed it.
        //
        // **P57b: there is NO `.strip()` anywhere on this path, and P57's
        // `strippedScalar` invented one.** `_bridge_section_to_env` exports
        // `str(section[key])` VERBATIM (`gateway/run.py:1816-1821` @
        // `v2026.9.7`) and `run_busy.py:727` compares `.lower()` of that to
        // the literal `"true"` — so quoted `' true'` is the string `" true"`,
        // which is not `"true"`, and the ack is DISABLED on the host while
        // post-P57 Scarf drew it ON. A trim is a per-READER claim about the
        // Hermes side (`_bool_token` really does `str(value).strip().lower()`,
        // `gateway/config.py:29-32`); it is not a reader-wide default.
        //
        // The two arms are therefore different vocabularies, and the QUOTES
        // are the whole difference — the same shape
        // ``HermesYAML/mattermostRequireMention(configScalar:)`` documents:
        //
        //   - QUOTED → a Python `str`, no resolver touches it, so the answer
        //     is `body.lower() == "true"` EXACTLY. `'yes'` and `'on'` are the
        //     strings `yes`/`on` and DISABLE the ack; only `'true'` (in any
        //     case) enables it. The body is escape-DECODED, because that is
        //     what PyYAML loaded.
        //   - BARE → PyYAML's bool resolver runs first, so its nine true
        //     spellings all become `True` → `"true"` → enabled; anything the
        //     resolver leaves a string is compared lowered, which is why a
        //     mixed-case `tRuE` (not in the resolver's regex) is ALSO enabled.
        //     An int is `str(int)` and never `"true"`, so `1` and `01`
        //     disable — the int resolver stays out of this key.
        //
        // Absent key → the bridge never runs → `os.environ.get(…, "true")` →
        // enabled, which is why this is still a true-by-default key.
        func busyAckEnabled() -> Bool {
            guard let raw = values["display.busy_ack_enabled"] else { return true }
            let body = HermesYAML.unquotedScalar(raw)
            if HermesYAML.isQuotedScalar(raw) { return body.lowercased() == "true" }
            return HermesYAML.pyYAMLTrue.contains(body) || body.lowercased() == "true"
        }
        func int(_ key: String, default def: Int) -> Int {
            Int(scalar(key) ?? "") ?? def
        }
        func double(_ key: String, default def: Double) -> Double {
            Double(scalar(key) ?? "") ?? def
        }
        func str(_ key: String, default def: String = "") -> String {
            let raw = values[key] ?? def
            return HermesYAML.stripYAMLQuotes(raw)
        }
        // Closed-enum string key: the value drives a `PickerRow`, so it has to
        // be the bare token. `str` only strips a surrounding quote pair, which
        // leaves `wal  # weak-fsync FS` (legal YAML for `wal`) as a selection
        // no picker option matches — the control renders blank and the next
        // save writes whatever the user then picks over a value they never
        // saw. `HermesYAML.normalizedScalar` strips the quotes AND the
        // whitespace-preceded trailing comment, exactly as the bool/int
        // readers above already do.
        //
        // Deliberately NOT validated against a fixed member set: Hermes adds
        // members to these enums between releases (`display.busy_input_mode`
        // grew `steer`, `agent.service_tier` grew `auto`/`cold`), and a client
        // that snapped an unknown member back to its default would hide a
        // value the host honours — and overwrite it on the next save. Hermes
        // itself normalises out-of-set values at READ time in its own reader
        // and leaves config.yaml alone; so does Scarf.
        func strEnum(_ key: String, default def: String = "") -> String {
            scalar(key) ?? def
        }
        // True-optional int: `nil` means "key absent from config.yaml",
        // distinct from any concrete int including 0. Used for
        // `database.wal_autocheckpoint` / `database.journal_size_limit`,
        // where Hermes reads `database.get(key)` directly and treats an
        // absent key differently from `0` (see DatabaseSettings doc).
        func intOpt(_ key: String) -> Int? {
            guard let raw = scalar(key) else { return nil }
            return Int(raw)
        }
        // Boolish true-optional: `nil` means "key absent OR unrecognised",
        // and a PRESENT value is read with Hermes's own boolish sets rather
        // than a literal `== "true"`. Truthy {true,1,yes,on} / falsy
        // {false,0,no,off} — `_TRUTHY_STRINGS`/`_FALSY_STRINGS`
        // (`gateway/config.py:25-26`), the same pair `_coerce_bool_extra`
        // uses (`plugins/platforms/telegram/adapter.py:1176-1186`); anything
        // else falls back to the host default, which for Scarf means
        // reporting "absent" so the display layer resolves it against the
        // host exactly as it would for a missing key.
        //
        // This is ALSO the reader for `checkpoints.enabled`, where absent
        // must stay distinguishable from an explicit `false` so the display
        // layer owns the host default rather than the parse baking one in
        // (`HermesConfig.displayCheckpointsEnabled`). A literal-`true`
        // variant of this reader existed for exactly that key and got
        // `checkpoints.enabled: yes` wrong in the one direction the sentinel
        // exists to protect.
        func boolishOpt(_ key: String) -> Bool? {
            HermesYAML.boolishValue(values[key])
        }
        // The boolean reader for a key with a KNOWN default (either polarity).
        // `def` is used only when the key is absent or carries a scalar in
        // neither boolish set; a present, recognised value always decides.
        func boolish(_ key: String, default def: Bool) -> Bool {
            boolishOpt(key) ?? def
        }

        let dockerEnv = maps["terminal.docker_env"] ?? [:]
        // `command_allowlist` is the ONLY spelling Hermes reads or writes:
        // `tools/approval.py::load_permanent_allowlist` does
        // `config.get("command_allowlist")` (:327-332 @ v2026.9.7) and
        // `save_permanent_allowlist` writes `config["command_allowlist"]`
        // (:358-366). A whole-tree grep for `permanent_allowlist` as a CONFIG
        // key finds nothing at any of the 32 `v2026.*` tags — the phrase only
        // ever names the two Python functions and the in-process set they
        // maintain. Preferring it here meant a config carrying BOTH keys
        // showed the one Hermes ignores, and `hermes approvals suggest
        // --apply` (which round-trips through `save_permanent_allowlist`)
        // wrote into the other.
        let commandAllowlist = lists["command_allowlist"] ?? []

        let display = DisplaySettings(
            skin: str("display.skin", default: "default"),
            compact: boolish("display.compact", default: false),
            resumeDisplay: strEnum("display.resume_display", default: "full"),
            bellOnComplete: boolish("display.bell_on_complete", default: false),
            inlineDiffs: boolTrueDefault("display.inline_diffs"),
            toolProgressCommand: boolish("display.tool_progress_command", default: false),
            toolPreviewLength: int("display.tool_preview_length", default: 0),
            busyInputMode: strEnum("display.busy_input_mode", default: "interrupt"),
            language: str("display.language"),
            timestamps: boolish("display.timestamps", default: false),
            // v0.21.1 keys. `resume_last_session` defaults TRUE upstream, so
            // an absent key must read `true` — reading it as `false` would
            // render the toggle off while the host resumes anyway.
            bellOnPrompt: boolish("display.bell_on_prompt", default: false),
            resumeLastSession: boolTrueDefault("display.resume_last_session")
        )

        let terminal = TerminalSettings(
            cwd: str("terminal.cwd", default: "."),
            timeout: int("terminal.timeout", default: 180),
            envPassthrough: lists["terminal.env_passthrough"] ?? [],
            persistentShell: boolTrueDefault("terminal.persistent_shell"),
            dockerImage: str("terminal.docker_image"),
            dockerMountCwdToWorkspace: boolish("terminal.docker_mount_cwd_to_workspace", default: false),
            dockerForwardEnv: lists["terminal.docker_forward_env"] ?? [],
            dockerVolumes: lists["terminal.docker_volumes"] ?? [],
            dockerExtraArgs: lists["terminal.docker_extra_args"] ?? [],
            // Hermes's own container limits, not zeroes. `config_defaults.py`
            // :318-321 @ v2026.9.7 reads `container_cpu: 1`,
            // `container_memory: 5120`, `container_disk: 51200`,
            // `container_persistent: True`, and a tag walk of DEFAULT_CONFIG
            // across all 32 `v2026.*` tags shows the same four values at every
            // tag from v2026.3.30 (v0.6.0, the supported minimum) onwards — so
            // these are literals, not sentinels. Parsing them as 0/0/0/false
            // rendered every container-backend host as "no CPU, no memory, no
            // disk, wiped between sessions".
            containerCPU: int("terminal.container_cpu", default: 1),
            containerMemory: int("terminal.container_memory", default: 5120),
            containerDisk: int("terminal.container_disk", default: 51200),
            containerPersistent: boolish("terminal.container_persistent", default: true),
            modalImage: str("terminal.modal_image"),
            modalMode: strEnum("terminal.modal_mode", default: "auto"),
            daytonaImage: str("terminal.daytona_image"),
            singularityImage: str("terminal.singularity_image")
        )

        let browser = BrowserSettings(
            inactivityTimeout: int("browser.inactivity_timeout", default: 120),
            commandTimeout: int("browser.command_timeout", default: 30),
            recordSessions: boolish("browser.record_sessions", default: false),
            allowPrivateURLs: boolish("browser.allow_private_urls", default: false),
            camofoxManagedPersistence: boolish("browser.camofox.managed_persistence", default: false)
        )

        let voice = VoiceSettings(
            recordKey: str("voice.record_key", default: "ctrl+b"),
            maxRecordingSeconds: int("voice.max_recording_seconds", default: 120),
            silenceDuration: double("voice.silence_duration", default: 3.0),
            ttsProvider: strEnum("tts.provider", default: "edge"),
            ttsEdgeVoice: str("tts.edge.voice", default: "en-US-AriaNeural"),
            ttsElevenLabsVoiceID: str("tts.elevenlabs.voice_id"),
            ttsElevenLabsModelID: str("tts.elevenlabs.model_id", default: "eleven_multilingual_v2"),
            ttsOpenAIModel: str("tts.openai.model", default: "gpt-4o-mini-tts"),
            ttsOpenAIVoice: strEnum("tts.openai.voice", default: "alloy"),
            ttsNeuTTSModel: str("tts.neutts.model"),
            ttsNeuTTSDevice: strEnum("tts.neutts.device", default: "cpu"),
            sttEnabled: boolTrueDefault("stt.enabled"),
            // Empty means the key is absent. Hermes v0.20.5 stopped seeding
            // `stt.provider` in config_defaults.py, so an absent key is the
            // autodetect ladder rather than `local`; defaulting to "local"
            // here would render an unset key as a pin. Older hosts seeded
            // `local`, which the picker surfaces via its "Auto" label — see
            // `SettingsViewModel.sttProviders`.
            sttProvider: strEnum("stt.provider"),
            sttLocalModel: strEnum("stt.local.model", default: "base"),
            sttLocalLanguage: str("stt.local.language"),
            sttOpenAIModel: str("stt.openai.model", default: "whisper-1"),
            sttMistralModel: str("stt.mistral.model", default: "voxtral-mini-latest"),
            ttsXAIVoiceID: str("tts.xai.voice_id"),
            // v0.15 round-trip — read the auto-speech-tags toggle back.
            ttsXAIAutoSpeechTags: boolish("tts.xai.auto_speech_tags", default: false),
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
            // v0.19.1 round-trip (hasSTTUnifiedLanguage).
            sttLanguage: str("stt.language", default: "en"),
            sttGroqModel: strEnum("stt.groq.model", default: "whisper-large-v3-turbo"),
            sttGroqLanguage: str("stt.groq.language"),
            // v0.19.1 round-trip (hasSTTLocalVADTuning).
            sttLocalVAD: boolTrueDefault("stt.local.vad"),
            sttLocalVADMinSilenceMS: int("stt.local.vad_min_silence_ms", default: 500),
            sttLocalNoSpeechProbThreshold: double("stt.local.no_speech_prob_threshold", default: 0.6),
            sttLocalLogprobThreshold: double("stt.local.logprob_threshold", default: -1.0),
            // v0.20.4 round-trip.
            sttLocalUnloadAfterIdleSeconds: int("stt.local.unload_after_idle_seconds", default: 0),
            // Top-level `stt.cloud_trim_*` — siblings of `stt.local.*`, NOT
            // nested under it.
            sttCloudTrimSilence: boolTrueDefault("stt.cloud_trim_silence"),
            sttCloudTrimThresholdDB: double("stt.cloud_trim_threshold_db", default: -40),
            sttCloudTrimKeepMS: int("stt.cloud_trim_keep_ms", default: 300),
            wakeWordCapture: strEnum("wake_word.capture", default: "auto"),
            // Default = Hermes's seed (`hermes_cli/config_defaults.py:1132`
            // @ v2026.9.14); see `VoiceSettings.voiceChatMode`.
            // `voice.gpt_live.*` is NOT read: the host script's
            // `create_webrtc_session` builds model, voice and instructions from
            // the host's own config (`build_session_config`,
            // `tools/voice_live.py:147` @ v2026.9.14), and no Scarf surface
            // shows them.
            voiceChatMode: str("voice.voice_chat_mode", default: "chained"),
            // Whole-`tts:`-section hash (t-eb402e82) — catches `tts.speed`
            // and command/plugin `tts.providers.<name>.*` sub-settings none
            // of the typed fields above model, so a cache keyed on it
            // invalidates on those edits too instead of replaying stale
            // audio.
            ttsSectionFingerprint: HermesYAML.ttsSectionFingerprint(
                values: values, lists: lists, maps: maps
            )
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
            enabled: boolTrueDefault("auxiliary.title_generation.enabled"),
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
            backgroundReviewEnabled: boolTrueDefault("auxiliary.background_review.enabled")
        )

        let security = SecuritySettings(
            redactSecrets: boolTrueDefault("security.redact_secrets"),
            redactPII: boolish("privacy.redact_pii", default: false),
            tirithEnabled: boolTrueDefault("security.tirith_enabled"),
            tirithPath: str("security.tirith_path", default: "tirith"),
            tirithTimeout: int("security.tirith_timeout", default: 5),
            tirithFailOpen: boolTrueDefault("security.tirith_fail_open"),
            blocklistEnabled: boolish("security.website_blocklist.enabled", default: false),
            blocklistDomains: lists["security.website_blocklist.domains"] ?? []
        )

        let humanDelay = HumanDelaySettings(
            mode: strEnum("human_delay.mode", default: "off"),
            minMS: int("human_delay.min_ms", default: 800),
            maxMS: int("human_delay.max_ms", default: 2500)
        )

        let compression = CompressionSettings(
            enabled: boolTrueDefault("compression.enabled"),
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
            progressNotices: boolish("compression.progress_notices", default: false)
        )

        // Sentinels, not defaults: an absent key must resolve against the
        // host in the display layer, never here — `HermesConfig
        // .displayCheckpointsEnabled` / `…MaxSnapshots`. Only
        // `max_snapshots` ever moved in the supported window (50 → 20 at
        // v0.13.0); `enabled` has read `cp_cfg.get("enabled", False)`
        // continuously since before the v0.6.0 minimum. Both resolvers carry
        // the per-tag walk.
        let checkpoints = CheckpointSettings(
            enabled: boolishOpt("checkpoints.enabled"),
            maxSnapshots: int("checkpoints.max_snapshots", default: 0)
        )

        let logging = LoggingSettings(
            level: strEnum("logging.level", default: "INFO"),
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
            maxConcurrentChildren: int("delegation.max_concurrent_children", default: 0),
            // v0.21.1 keys. Here Hermes's own default (0 = no subagent cap)
            // and the "absent" reading coincide, so no sentinel is needed.
            independentCompletions: boolish("delegation.independent_completions", default: false),
            compressionThresholdTokens: int("delegation.compression_threshold_tokens", default: 0)
        )

        let discord = DiscordSettings(
            requireMention: boolTrueDefault("discord.require_mention"),
            freeResponseChannels: str("discord.free_response_channels"),
            autoThread: boolTrueDefault("discord.auto_thread"),
            reactions: boolTrueDefault("discord.reactions"),
            historyBackfill: boolTrueDefault("discord.history_backfill"),
            allowAnyAttachment: boolish("platforms.discord.extra.allow_any_attachment", default: false)
        )

        let telegram = TelegramSettings(
            // FALSE by default, matching Hermes's only reader:
            // `telegram.require_mention` has no `config_defaults.py` entry at
            // ANY of the 32 `v2026.*` tags (so P13's "schema layer wins" rule
            // never engages and the reader's own fallback IS the default), and
            // the reader is `_extra_bool("require_mention",
            // "TELEGRAM_REQUIRE_MENTION", "false")` —
            // `plugins/platforms/telegram/adapter.py:5030` @ v2026.9.7. Scarf
            // carried `true` deliberately as a known divergence pending this
            // phase; it rendered "mention required" on every stock host, i.e.
            // the opposite of the group behaviour the user actually gets.
            //
            // `require_mention` is a `_SHARED_KEYS` member for every platform,
            // not just Slack, so the same bridge precedence applies here.
            requireMention: sharedPlatformBool("telegram", "require_mention", default: false),
            reactions: boolish("telegram.reactions", default: false),
            disableTopicAutoRename: boolish("telegram.disable_topic_auto_rename", default: false),
            ignoreRootDM: boolish("platforms.telegram.extra.ignore_root_dm", default: false),
            // Sentinel, not a default: Hermes flipped the shipped default
            // true -> false at v0.18.0, one release after the key landed. See
            // `TelegramSettings.richMessages` and
            // `HermesConfig.displayTelegramRichMessages(capabilities:)`.
            richMessages: boolishOpt("platforms.telegram.extra.rich_messages"),
            statusIndicator: boolish("platforms.telegram.extra.status_indicator", default: false)
        )

        // -- v0.15: Signal group-only require_mention + ntfy (23rd platform).
        let signal = SignalSettings(
            requireMention: boolish("platforms.signal.extra.require_mention", default: false)
        )

        let ntfy = NtfySettings(
            topic: str("platforms.ntfy.extra.topic"),
            server: str("platforms.ntfy.extra.server", default: "https://ntfy.sh"),
            publishTopic: str("platforms.ntfy.extra.publish_topic"),
            token: str("platforms.ntfy.extra.token"),
            markdown: boolish("platforms.ntfy.extra.markdown", default: false)
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
            enabled: boolish("secrets.bitwarden.enabled", default: false),
            accessTokenEnv: str("secrets.bitwarden.access_token_env", default: "BWS_ACCESS_TOKEN"),
            projectID: str("secrets.bitwarden.project_id"),
            // TRUE upstream, and true at every tag that HAS the key:
            // `config_defaults.py:2174` @ v2026.9.7, and the `secrets.bitwarden`
            // block's very first appearance (v2026.5.28 = v0.15.0) already
            // reads `"override_existing": True`. No earlier tag has a
            // `bitwarden` section at all, so there is no host generation this
            // could be a sentinel for. Reading it `false` told users a rotated
            // Bitwarden secret would NOT overwrite a stale `.env` line, when it
            // does.
            overrideExisting: boolish("secrets.bitwarden.override_existing", default: true),
            serverURL: str("secrets.bitwarden.server_url"),
            cacheTTLSeconds: int("secrets.bitwarden.cache_ttl_seconds", default: 300),
            autoInstall: boolTrueDefault("secrets.bitwarden.auto_install"),
            // `secrets.bitwarden.encrypted_cache` — v0.20+ (commit
            // 1384087729, first released v2026.7.30). `max_stale_seconds`
            // defaults to 0 ("no stale fallback"), a real value distinct
            // from unset.
            encryptedCache: BitwardenEncryptedCacheSettings(
                enabled: boolish("secrets.bitwarden.encrypted_cache.enabled", default: false),
                maxStaleSeconds: int("secrets.bitwarden.encrypted_cache.max_stale_seconds", default: 0)
            )
        )

        // `secrets.command.*` — v0.20+ any-CLI vault helper secret source
        // (commit 3d5dd8efa5, first released v2026.7.30). See
        // `CommandSecretsSettings` for the trust-model note on `command`.
        let commandSecrets = CommandSecretsSettings(
            enabled: boolish("secrets.command.enabled", default: false),
            command: str("secrets.command.command"),
            helperTimeoutSeconds: double("secrets.command.helper_timeout_seconds", default: 3.0),
            overrideExisting: boolish("secrets.command.override_existing", default: false)
        )

        // `telemetry.shared_metrics` — v0.20+ opt-in local aggregate
        // metrics (Relay pipeline, first released v2026.7.30).
        let telemetry = TelemetrySettings(
            sharedMetricsEnabled: boolish("telemetry.shared_metrics.enabled", default: false),
            // v0.21.1 transmission opt-in + its endpoint. `send` is read
            // independently of `enabled` so the UI can show the true stored
            // state; Hermes itself refuses to transmit without `enabled`.
            sharedMetricsSend: boolish("telemetry.shared_metrics.send", default: false),
            sharedMetricsEndpoint: str("telemetry.shared_metrics.endpoint")
        )

        // `database.*` — SQLite journal/WAL sizing pragmas, v0.20+ (first
        // released v2026.7.30). `wal_autocheckpoint` / `journal_size_limit`
        // are true optionals: absent key != 0.
        let database = DatabaseSettings(
            journalMode: strEnum("database.journal_mode", default: "wal"),
            walAutocheckpoint: intOpt("database.wal_autocheckpoint"),
            journalSizeLimit: intOpt("database.journal_size_limit")
        )

        let slack = SlackSettings(
            // `platforms.slack.reply_to_mode` ONLY. This is the mattermost bug
            // P13 fixed, in the other direction: `reply_to_mode` is a field of
            // `PlatformConfig`, read by `from_dict` off the per-platform dict
            // `merge_platform_sections` assembles (`gateway/config.py:437`),
            // and that merge only ever consumes `gateway.platforms.<p>`,
            // `platforms.<p>` and `gateway.<p>` — never a BARE top-level
            // `slack:` block (`config_loader.py:149-152`). `reply_to_mode` is
            // also absent from `_SHARED_KEYS` (:197-215), so the bridge does
            // not carry it either, and slack's own `_apply_yaml_config` hook
            // (`plugins/platforms/slack/adapter.py:6449`) lists every key it
            // translates and `reply_to_mode` is not among them. A top-level
            // `slack.reply_to_mode` is therefore read by no Hermes version, and
            // reading it here claimed a setting was live that the host ignores.
            // Scarf's writer already only writes the nested spelling
            // (`SlackSetupViewModel.swift:63`), so nothing Scarf produced is
            // affected — only a hand-written config.
            replyToMode: values["platforms.slack.reply_to_mode"] ?? "first",
            // `require_mention` and `reply_in_thread` are both `_SHARED_KEYS`
            // members (`gateway/config_loader.py:200` @ v2026.9.7), so both go
            // through `sharedPlatformScalar`'s precedence — see its doc block.
            // Reading `reply_in_thread` from `extra:` only was the live bug: a
            // top-level `slack.reply_in_thread` is bridged in and OVERWRITES
            // the `extra:` value, so Scarf showed the losing half.
            //
            // Defaults verified at v2026.9.7: `require_mention` True (the
            // adapter's `_slack_require_mention`, `adapter.py:5917-5926`,
            // treats an unrecognised or absent value as gating-on),
            // `reply_in_thread` True (no schema default — the adapter's own
            // reader, `gateway/relay/adapter.py:787` and
            // `gateway/run_turn.py:2790`, both `.get("reply_in_thread", True)`),
            // `reply_broadcast` False.
            requireMention: sharedPlatformBool("slack", "require_mention", default: true),
            replyInThread: sharedPlatformBool("slack", "reply_in_thread", default: true),
            replyBroadcast: boolish("platforms.slack.extra.reply_broadcast", default: false)
        )

        let matrix = MatrixSettings(
            requireMention: boolTrueDefault("matrix.require_mention"),
            // Default TRUE upstream — no `config_defaults.py` entry, the
            // default lives in the reader:
            // `plugins/platforms/matrix/adapter.py:799`
            // `_env_truthy("MATRIX_AUTO_THREAD", "true")`.
            autoThread: boolTrueDefault("matrix.auto_thread"),
            dmMentionThreads: boolish("matrix.dm_mention_threads", default: false)
        )

        let mattermost = MattermostSettings(
            // `require_mention` is a `_SHARED_KEYS` member
            // (`gateway/config_loader.py:197-213` @ `v2026.9.7`), so the
            // section Hermes bridges it from is the one `platform_section`
            // picks (`:171-180`) — NOT the top-level spelling unconditionally.
            // Reading it flat was the reader half of P51's write: the form
            // wrote bare `mattermost.require_mention`, which CREATES the
            // top-level block on a nested-only host and un-bridges every
            // `platforms.mattermost.<shared key>` beside it (P46b's "leaving a
            // write on its bare spelling is not neutral" lesson). Read and
            // write move together — the pair is on
            // `HermesPlatformSharedKeys.bridgeResolvedKeys` now, so the write
            // lands wherever the bridge source already is.
            requireMention: mattermostRequireMention(default: true),
            // `platforms.mattermost.extra.reply_mode`, NOT the top-level
            // `mattermost.reply_mode` Scarf used to read. The adapter reads
            // `config.extra` only —
            // `plugins/platforms/mattermost/adapter.py:120-121`
            // `config.extra.get("reply_mode", "") or _get_scoped_secret("MATTERMOST_REPLY_MODE", "off")`
            // — and `reply_mode` is not one of `gateway/config_loader.py`'s
            // `_SHARED_KEYS`, so a top-level spelling is never bridged into
            // `extra` and Hermes never sees it. The env fallback
            // (`MATTERMOST_REPLY_MODE`, which is what `MattermostSetupView`
            // actually edits) lives in `.env`, outside this parse; an absent
            // YAML key reads as the same `off` it always did.
            replyMode: strEnum("platforms.mattermost.extra.reply_mode", default: "off"),
            // Presence, not value. `sharedPlatformBool` above resolves the key
            // the way the adapter does; this says whether the key is THERE,
            // which is what lets `MattermostSetupViewModel` fall back to
            // `MATTERMOST_REQUIRE_MENTION` exactly when Hermes would
            // (`plugins/platforms/mattermost/adapter.py:491-494`, `:504` @
            // `v2026.9.7`) instead of showing config's resolved default over
            // a live `.env` value.
            // Presence is asked at the SAME precedence as the value, or the
            // fallback would fire for a key that is there (nested) and not
            // fire for one that is not.
            // Same coercion as `requireMention` above — the mattermost one,
            // not the universal boolish set — or the form's fallback arm
            // would show a value the gateway does not hold (round-6 P53).
            requireMentionIsSet: sharedPlatformScalar("mattermost", "require_mention") != nil
                ? mattermostRequireMention(default: true)
                : nil
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
            watchAll: boolish("platforms.homeassistant.extra.watch_all", default: false),
            ignoreEntities: lists["platforms.homeassistant.extra.ignore_entities"] ?? [],
            cooldownSeconds: int("platforms.homeassistant.extra.cooldown_seconds", default: 30)
        )

        // -- v0.13: per-platform Messaging Gateway settings --------------
        // Allowlists live at top-level `<platform>.allowed_*` (verified
        // v0.16): `slack.allowed_channels`, `telegram.allowed_chats`,
        // `matrix.allowed_rooms`, `dingtalk.allowed_chats`, plus the
        // top-level `<platform>.gateway_restart_notification` toggle.
        // `busy_ack_enabled` is a no-op per-platform (Hermes reads only the
        // global `display.busy_ack_enabled`) but is kept for round-trip;
        // `slash_command_notice_ttl_seconds` was dropped entirely in the
        // v0.21.1 B5 sweep — no Hermes version defines it.
        // Platforms without an explicit block don't appear in the
        // dictionary, so the editor's
        // `?? .empty` fallback hands the user the defaults without leaving
        // stale keys littered across the YAML.
        // `google_chat` has no allowlist (its adapter gates access via
        // GOOGLE_CHAT_ALLOWED_USERS, never an allowed_channels list) but it
        // DOES get a `GatewayBehaviorSection`, so Scarf writes its
        // `google_chat.gateway_restart_notification`. Leaving it out of this
        // loop made that toggle a write-only key: it saved, then the next
        // load read `false` and the switch snapped back. The allowlists
        // simply come back empty for it.
        // `discord` joins the loop with the v0.21.1 B4 fix: its real
        // `discord.allowed_channels` allowlist is now mapped by
        // `GatewayAllowlistKind` and edited from `DiscordSetupView`, so it
        // must be READ here too or the list would save and read back empty
        // (the same write-only-key bug `google_chat` had).
        let gatewayAllowlistPlatforms = [
            "slack", "mattermost", "discord",
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
            let busy            = boolTrueDefault(prefix + "busy_ack_enabled")
            // Upstream default is TRUE (`gateway/config.py` PlatformConfig),
            // so an absent key — and any non-`true` spelling of a truthy
            // value — must NOT read as off. See `boolTrueDefault`.
            // P46b: `gateway_restart_notification` is a `_SHARED_KEYS`
            // member, and reading it from the bare top-level spelling alone
            // is what made `GatewayBehaviorViewModel`'s toggle CREATE a
            // top-level `<platform>:` block on a nested-only host —
            // `platform_section` then bridges from that block
            // (`gateway/config_loader.py:171-180` @ `v2026.9.7`) and every
            // nested shared key beside it (`platforms.slack.require_mention`
            // …) stops reaching `extra`. Read through the bridge and the
            // write lands wherever the bridge source already is, creating
            // nothing.
            //
            // Only `slack` and `telegram` are moved, because those are the
            // platforms whose OTHER shared keys Scarf reads through the
            // bridge (`HermesPlatformSharedKeys.bridgeResolvedKeys`) and so
            // the only ones a created block can un-bridge anything on. The
            // remaining six keep the flat spelling; the general hazard —
            // ANY bare `<platform>.<unshared>` key creating a block — is
            // filed, not closed here.
            let restartRaw: String?
            switch platform {
            case "slack":
                restartRaw = sharedPlatformScalar("slack", "gateway_restart_notification")
            case "telegram":
                restartRaw = sharedPlatformScalar("telegram", "gateway_restart_notification")
            default:
                restartRaw = values[prefix + "gateway_restart_notification"]
            }
            // `boolTrueDefault`'s rule, over a scalar this reader resolved
            // itself: absent means the host IS notifying, and only an
            // explicit falsy spelling turns it off.
            // P57: `boolTrueDefault`'s rule is now a call, not a copy — the
            // copy compared the quoted body verbatim and knew no int
            // resolver, so `" false"` and `0x0` read as ON.
            let restartNotice = HermesYAML.boolishValue(restartRaw) != false
            // Skip platforms with no v0.13 fields present anywhere in the
            // file. Without this guard, every supported platform would
            // round-trip an all-default block back through writes even
            // when the user never touched the new surface.
            let isEmpty = allowedChannels.isEmpty
                && allowedChats.isEmpty
                && allowedRooms.isEmpty
                && values[prefix + "busy_ack_enabled"] == nil
                && restartRaw == nil
            if !isEmpty {
                gatewayPlatforms[platform] = GatewayPlatformSettings(
                    allowedChannels: allowedChannels,
                    allowedChats: allowedChats,
                    allowedRooms: allowedRooms,
                    busyAckEnabled: busy,
                    gatewayRestartNotification: restartNotice
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
            personality: strEnum("display.personality", default: "default"),
            terminalBackend: strEnum("terminal.backend", default: "local"),
            // Hermes's real `memory` defaults, not zeroes/off. Verified in
            // BOTH layers at v2026.9.7 and walked across all 32 `v2026.*`
            // tags: `config_defaults.py:1194,1200,1203` reads
            // `memory_enabled: True`, `memory_char_limit: 2200`,
            // `user_char_limit: 1375`, and the reader agrees —
            // `agent/agent_init.py:1263,1266` `mem_config.get("nudge_interval",
            // 10)` / `.get("memory_char_limit", 2200)` /
            // `.get("user_char_limit", 1375)`. The three values are IDENTICAL
            // at every tag from v2026.3.30 (v0.6.0) on, so they are literals
            // rather than `checkpoints.enabled`-style sentinels.
            //
            // `nudge_interval` is the one with a layer split: it enters
            // `config_defaults.py` only at v2026.8.19 (v0.20.5) and is absent
            // from the schema before that — but the reader's own fallback has
            // been `10` since the key's first reader (v2026.5.28 / v0.15.0
            // `agent_init.py:1078`), and no earlier tag reads the key at all.
            // So the EFFECTIVE default is 10 on every host that has the
            // feature, again a literal.
            //
            // The zeroes were not merely cosmetic: `MemoryTab`'s steppers range
            // `500...10_000` and `1...50`, so an absent key rendered each row
            // outside its own range and the first tap jumped to the range
            // floor, writing 500/500/1 over host defaults of 2200/1375/10.
            memoryEnabled: boolish("memory.memory_enabled", default: true),
            memoryCharLimit: int("memory.memory_char_limit", default: 2200),
            userCharLimit: int("memory.user_char_limit", default: 1375),
            nudgeInterval: int("memory.nudge_interval", default: 10),
            // `display.streaming` defaults to **false** upstream and always
            // has: `hermes_cli/config_defaults.py:796` seeds
            // `display.streaming: False` (and did at every tag back to
            // v2026.3.17 = v0.3, under the old `hermes_cli/config.py`
            // DEFAULT_CONFIG), and its only reader agrees —
            // `cli.py:2598  self.streaming_enabled = display.get("streaming", False)`.
            // Scarf read it as `!= "false"`, which is BOTH a wrong default
            // (absent key rendered the toggle ON while the host streams
            // nothing) and a raw compare that bypasses
            // `HermesYAML.normalizedScalar`, so `true  # for now` read as
            // false. This is display-layer only — see `modelStreaming` for
            // the provider-request switch, which really does default true.
            streaming: boolish("display.streaming", default: false),
            // Sentinel, not a default: the shipped default flipped False →
            // TRUE at tag v2026.7.7 (v0.18.1) and has stayed true through
            // v2026.9.7, so an absent key means different things on two host
            // generations inside the supported window. Resolved by
            // `HermesConfig.displayShowReasoning(capabilities:)`.
            //
            // Note the audit's citation was one release out: the flip is at
            // v2026.7.7 (0.18.1) `hermes_cli/config.py`, not v2026.7.20
            // (0.19.0) — v2026.7.7.2 (0.18.2) already ships `True`, and
            // v2026.7.1 (0.18.0) still ships `False`. The reader agrees at the
            // target (`cli.py:2584` @ v2026.9.7, `display.get("show_reasoning",
            // True)`), but the schema layer is the authority here because
            // `display.show_reasoning` is present in `DEFAULT_CONFIG` at every
            // supported tag (P13's "the reader's fallback is unreachable for a
            // key the schema seeds" rule).
            showReasoning: boolishOpt("display.show_reasoning"),
            // TRUE-by-default; read through `boolTrueDefault` rather than a
            // raw `!= "false"` so `no`/`off`/`0` (and `false  # comment`)
            // turn it off the way Hermes's own boolish readers do.
            // FALSE in both layers and at every tag in the window:
            // `config_defaults.py:1121` @ v2026.9.7 `"auto_tts": False`, and
            // the reader `hermes_cli/cli_voice_mixin.py:516`
            // `_config_section("voice").get("auto_tts", False)`. A tag walk of
            // DEFAULT_CONFIG shows `False` at every tag from v2026.3.30
            // (v0.6.0). `boolTrueDefault` rendered the toggle ON for every user
            // whose config omits the key — i.e. it claimed every reply would be
            // spoken aloud.
            autoTTS: boolish("voice.auto_tts", default: false),
            silenceThreshold: int("voice.silence_threshold", default: QueryDefaults.defaultSilenceThreshold),
            // EMPTY means absent, and absent means "whatever the provider
            // does" — not `medium`. `agent.reasoning_effort` appears in NO
            // schema layer at any of the 32 `v2026.*` tags (the only
            // `reasoning_effort` entries in `config_defaults.py` are the
            // per-`auxiliary` ones, seeded `""`), so there is no default to
            // mirror; `hermes_constants.py:876-889` `parse_reasoning_effort`
            // returns `None` for an empty/unrecognised value and its callers
            // then "use the default", which is the model provider's own. The
            // picker renders this as a distinct "Hermes default" row rather
            // than asserting a level Hermes never chose.
            reasoningEffort: strEnum("agent.reasoning_effort"),
            showCost: boolish("display.show_cost", default: false),
            // Sentinel (empty = absent), not `manual`: the schema default
            // flipped `manual` → `smart` at tag v2026.7.20 (v0.19.0) and has
            // been `smart` ever since (`config_defaults.py:1534` @ v2026.9.7;
            // `hermes_cli/config.py` still reads `"manual"` at v2026.7.7.2 =
            // v0.18.2). The reader's own fallback IS `manual`
            // (`tools/approval_context.py:236`) but it is unreachable for a key
            // the schema seeds, so reading `manual` told every stock v0.19+
            // user that Scarf would ask before every guarded command when the
            // guardian model was actually deciding — the dangerous direction.
            // Resolved by `HermesConfig.displayApprovalMode(capabilities:)`.
            approvalMode: strEnum("approvals.mode"),
            // The RAW scalar, quotes intact — `HermesApprovalMode.normalize`
            // needs to tell a quoted `"no"` (a `str`, i.e. `manual` to
            // Hermes) from a bare `no` (a bool, i.e. `off`). Every other
            // reader wants the normalised form above.
            approvalModeRawScalar: values["approvals.mode"] ?? "",
            browserCloudProvider: strEnum("browser.cloud_provider"),
            memoryProvider: strEnum("memory.provider"),
            dockerEnv: dockerEnv,
            commandAllowlist: commandAllowlist,
            memoryProfile: str("memory.profile"),
            serviceTier: str("agent.service_tier", default: "normal"),
            // True optional, because `0` is a MEANINGFUL value for this key
            // ("still working" notices off) and so cannot double as the absence
            // sentinel the way `agent.max_turns`' 0 does. The default changed
            // inside the window: absent from DEFAULT_CONFIG before v2026.4.13
            // (v0.9.0), `600` at v0.9.0–v0.10.0, and `180` from v2026.4.23
            // (v0.11.0) through v2026.9.7 (`config_defaults.py:196`). Resolved
            // by `HermesConfig.displayGatewayNotifyInterval(capabilities:)`.
            gatewayNotifyInterval: intOpt("agent.gateway_notify_interval"),
            forceIPv4: boolish("network.force_ipv4", default: false),
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
            interimAssistantMessages: boolTrueDefault("display.interim_assistant_messages"),
            honchoInitOnSessionStart: boolish("honcho.initOnSessionStart", default: false),
            timezone: str("timezone"),
            userProfileEnabled: boolTrueDefault("memory.user_profile_enabled"),
            toolUseEnforcement: strEnum("agent.tool_use_enforcement", default: "auto"),
            gatewayTimeout: int("agent.gateway_timeout", default: 1800),
            cronDrainTimeout: int("agent.cron_drain_timeout", default: 30),
            // 0 is the "key absent" sentinel, NOT a real default — the
            // upstream default changed at v0.21.0 (1800 → 5). Display
            // surfaces resolve it via
            // `displayGatewayTurnLeaseTimeout(capabilities:)`.
            gatewayTurnLeaseTimeout: int("agent.gateway_turn_lease_timeout", default: 0),
            // 0 = "key absent" sentinel. An explicit `0` IS honoured upstream
            // and is therefore indistinguishable here — see the field's doc
            // comment for why that is safe (Scarf's stepper floor is 5). The
            // shipped default changed inside the window: `60` from v2026.3.30
            // (v0.6.0) through v2026.7.20 (v0.19.0), `300` from v2026.7.30
            // (v0.19.1) onwards — `config_defaults.py:1535` @ v2026.9.7, and
            // the reader agrees (`tools/approval_context.py:240-249`,
            // `.get("timeout", 300)`, whose docstring names the change: "60s
            // failed closed before Telegram taps landed"). Resolved by
            // `HermesConfig.displayApprovalTimeout(capabilities:)`.
            approvalTimeout: int("approvals.timeout", default: 0),
            fileReadMaxChars: int("file_read_max_chars", default: 100_000),
            cronWrapResponse: boolTrueDefault("cron.wrap_response"),
            curatorConsolidate: boolish("curator.consolidate", default: false),
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
            runtimeMetadataFooter: boolish("display.runtime_footer.enabled", default: false),
            // Default TRUE upstream, again from the reader rather than the
            // schema: `gateway/run.py:1813` bridges `display.busy_ack_enabled`
            // to `HERMES_GATEWAY_BUSY_ACK_ENABLED`, and `run_busy.py:727`
            // reads `os.environ.get(..., "true").lower() != "true"`.
            displayBusyAckEnabled: busyAckEnabled(),
            gatewayPlatforms: gatewayPlatforms,
            // -- v0.13 additions -------------------------------------
            // `openrouter.response_cache` is a SCALAR bool directly under
            // `openrouter:` and its upstream default is **true** — verified at
            // `hermes_cli/config_defaults.py:649` (v2026.9.7) and, at the key's
            // FLOOR, `hermes_cli/config.py:686` at v2026.5.7 (v0.13.0, where
            // the key first appears); True at every tag in between. The
            // reader's own fallback reads False
            // (`agent/auxiliary_client.py:860`
            // `or_config.get("response_cache", False)`), but that arm is
            // unreachable for an absent key: `_load_config_impl`
            // (`hermes_cli/config.py:2197,2211`) starts from
            // `deepcopy(DEFAULT_CONFIG)` and deep-merges the user's file over
            // it, so `openrouter.response_cache` is always present by the time
            // any reader sees it. Scarf's `false` therefore rendered the
            // toggle OFF on a host that was caching, and one save wrote the
            // `false` the user never chose — the `gateway_restart_notification`
            // trap again. A legacy nested value
            // (`openrouter.response_cache.enabled: …`) flattens to a different
            // dotted key, so it has no scalar entry here and now decodes to
            // the correct `true`; the next save writes the scalar, healing the
            // shape. Keep in lockstep with the matching `setSetting` key in
            // `SettingsViewModel.setOpenRouterResponseCache`.
            imageGenModel: str("image_gen.model", default: ""),
            openrouterResponseCacheEnabled: boolTrueDefault("openrouter.response_cache"),
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
            // A top-level key takes PRECEDENCE over `gateway.*` by PRESENCE
            // (`gateway/config_loader.py:75` presence bridge;
            // `gateway/config.py:668-670` `pick()`, consumed at `:734`
            // @ `v2026.9.7`) — mirrors the top-level-wins
            // pattern `ProfileRoutesYAML.parse` uses for `multiplex_profiles`.
            // `nil` = key absent from config.yaml at either spelling
            // (serve-all). A malformed value — present as a scalar, or as a
            // mapping (a section header with children but no bullet list) —
            // is normalized to `[]`, matching upstream's fail-safe of
            // serving only the "default" profile, rather than failing open
            // (nil → serve-all) or being silently dropped.
            multiplexProfileAllowlist: Self.multiplexProfileAllowlist(
                values: values, lists: lists, maps: maps
            ),
            // v0.21.1 scalars. Window length for the bounded `auto`/`cold`
            // service tiers; Hermes's own default is 60 and has never been
            // anything else, so the parse default IS the host default.
            agentFastAutoSeconds: int("agent.fast_auto_seconds", default: 60),
            // The next four all default TRUE upstream, so an absent key must
            // read `true` — reading `false` would render every toggle off
            // while the host does the opposite. `model.streaming` gets its
            // default from its READER (`agent/agent_init.py`
            // `_model_section.get("streaming", "true")`), not from
            // `config_defaults.py`, and `tool_loop_guardrails` is a
            // TOP-LEVEL block, not a child of `agent.`.
            gatewayTrustEnv: boolTrueDefault("gateway.trust_env"),
            updatesCheck: boolTrueDefault("updates.check"),
            modelStreaming: boolTrueDefault("model.streaming"),
            toolLoopNonInteractiveHardStop: boolTrueDefault(
                "tool_loop_guardrails.non_interactive_hard_stop_enabled"
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
        /// Null spellings PyYAML loads as `None`. A present-but-null key is
        /// NOT a malformed value: `pick` hands `None` straight to
        /// `_normalize_multiplex_profile_allowlist`, whose first line is
        /// `if value is None: return None` (`gateway/config.py:45-48` @
        /// v2026.9.7) — i.e. serve ALL profiles, the same as an absent key.
        /// Failing closed to `[]` there told the user their gateway was
        /// restricted to the `default` profile when it was not. (A bare
        /// `multiplex_profile_allowlist:` with no value never reaches this
        /// function at all — `parseNestedYAML` treats an empty value as a
        /// section header and records no scalar — so the explicit spellings
        /// are the cases that need handling.)
        func isNullScalar(_ raw: String) -> Bool {
            // `null` / `~` only. An EMPTY scalar is deliberately not null
            // here: a bare `key:` never reaches `values` at all (see above),
            // so the only way to get `""` is an explicitly quoted `key: ''`,
            // which PyYAML loads as the empty STRING — not a list, so Hermes
            // warns and fails closed to `[]` like any other malformed value.
            let v = HermesYAML.normalizedScalar(raw).lowercased()
            return v == "null" || v == "~"
        }
        /// `.some(value)` when the key is PRESENT (the value may itself be
        /// `nil` = serve all), `.none` when it is absent. Hermes's `pick`
        /// (`gateway/config.py:668-670`) selects on PRESENCE — `data[key] if
        /// key in data else nested_gateway.get(key)` — so a present top-level
        /// key shadows the nested one even when its value is null.
        func resolve(_ key: String) -> [String]?? {
            if let list = lists[key] { return .some(list) }
            if let raw = values[key] { return .some(isNullScalar(raw) ? nil : []) }
            // A mapping-valued key (section header with `key: value`
            // children but no bullet list) fails CLOSED to `[]` — Hermes
            // restricts to the default profile rather than serving all.
            if maps[key]?.isEmpty == false { return .some([]) }
            return .none
        }
        if let resolved = resolve("multiplex_profile_allowlist") { return resolved }
        if let resolved = resolve("gateway.multiplex_profile_allowlist") { return resolved }
        return nil
    }
}
