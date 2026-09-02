import Foundation
import ScarfCore
import AppKit
import UniformTypeIdentifiers
import os

@Observable
final class SettingsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "SettingsViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var rawConfigYAML = ""
    var personalities: [String] = []
    // tts.provider gained `piper` (native local TTS via the Piper engine)
    // in v0.12. Shows up unconditionally — Hermes silently ignores unknown
    // values on older hosts. (Vercel Sandbox was removed as a terminal
    // backend in v0.15 alongside the Vercel AI Gateway provider removal.)
    var terminalBackends = ["local", "docker", "singularity", "modal", "daytona", "ssh"]
    /// `browser.cloud_provider` options. The ids are Hermes' own provider
    /// names: `local` and `camofox` are hardcoded rows in
    /// `hermes_cli/tools_config.py`'s Browser Automation section, while
    /// `browser-use` / `browserbase` / `firecrawl` come from the bundled
    /// `plugins/browser/*/provider.py` `.name` properties (note the hyphen
    /// in `browser-use` — `browseruse`, which Scarf wrote until 2.18.1, is
    /// not a registered provider and makes Hermes log a warning and fall
    /// back to auto-detect).
    ///
    /// The leading empty row means "auto-detect": with
    /// `browser.cloud_provider` absent, `tools/browser_tool._get_cloud_provider`
    /// tries Browser Use then Browserbase by credentials. That is NOT the
    /// same as `local`, which explicitly disables cloud dispatch — so
    /// `setBrowserCloudProvider` routes it to `hermes config unset` rather
    /// than writing an empty scalar (an empty value normalizes to `local`).
    ///
    /// `browser.cloud_provider` has existed since Hermes v0.4.0
    /// (`v2026.3.23`), well below Scarf's minimum supported host, so this
    /// picker needs no capability gate.
    var browserCloudProviders: [(id: String, label: String)] = [
        ("",            "Auto-detect (default)"),
        ("local",       "Local Browser"),
        ("browser-use", "Browser Use"),
        ("browserbase", "Browserbase"),
        ("firecrawl",   "Firecrawl"),
        ("camofox",     "Camofox"),
    ]
    // v0.13: `xai` joins the TTS provider list. xAI shipped TTS earlier
    // (v0.12) but the v0.13 add-on is custom voice cloning — see
    // `HermesCapabilities.hasXAIVoiceCloning` and the badge in VoiceTab.
    // The provider option itself is ungated so pre-v0.13 hosts with xAI
    // keys can still pick it.
    var ttsProviders = ["edge", "elevenlabs", "openai", "minimax", "mistral", "neutts", "piper", "xai", "deepinfra"]
    /// `stt.provider` options. The leading empty row means "key absent —
    /// Hermes decides".
    ///
    /// Hermes v0.20.5 stopped seeding `stt.provider` in `config_defaults.py`:
    /// an absent key runs the autodetect ladder, and a stored value is an
    /// explicit pin. On pre-v0.20.5 hosts absent meant the seeded `local`
    /// default. The row is therefore offered **ungated by host version** —
    /// "let Hermes choose" is the honest description of an absent key on
    /// every supported host, and it is the only way back out of a pin — but
    /// it is gated on `hasConfigUnset` (v0.19+) in the view, because it must
    /// be written with `hermes config unset` rather than an empty scalar.
    var sttProviders: [(id: String, label: String)] = [
        ("",        "Auto (unset)"),
        ("local",   "Local"),
        ("groq",    "Groq"),
        ("openai",  "OpenAI"),
        ("mistral", "Mistral"),
    ]
    /// Static-message translation languages honored by Hermes v0.13's
    /// `display.language` key. The first row's empty value writes no
    /// key — equivalent to "Hermes default" — while explicit `en` writes
    /// the code so users who care about determinism can pin it. Keep the
    /// label list in sync with the Hermes v0.13 release notes; new
    /// languages should be appended in alphabetical order by display
    /// label so the picker stays scannable.
    var displayLanguages: [(code: String, label: String)] = [
        ("",   "English (default)"),
        ("en", "English"),
        ("zh", "中文 (Chinese)"),
        ("ja", "日本語 (Japanese)"),
        ("de", "Deutsch (German)"),
        ("es", "Español (Spanish)"),
        ("fr", "Français (French)"),
        ("uk", "Українська (Ukrainian)"),
        ("tr", "Türkçe (Turkish)"),
    ]
    var memoryProviders = ["", "honcho", "openviking", "mem0", "hindsight", "holographic", "retaindb", "byterover", "supermemory"]
    var saveMessage: String?
    var isLoading = false

    /// `hasLoaded` lets a plain section re-entry skip the config/env re-read
    /// (the VM is cached in `AppCoordinator` and persists across switches);
    /// Reload and post-save reloads pass `force: true` (t-aud24).
    @ObservationIgnored private var hasLoaded = false

    /// Host capability, pushed in by `SettingsView` from
    /// `\.hermesCapabilities` before `load()`. See `parsePersonalities()`.
    /// Defaults to `false` — the conservative reading (show only what the
    /// config actually contains) until capabilities are known.
    var hasBuiltinPersonalitiesInCode: Bool = false

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        let svc = fileService
        let ctx = context
        let displayName = ctx.displayName
        let log = logger
        // Heavy load: config + gateway state + isRunning + raw YAML are
        // four sync transport calls. On remote each is a blocking ssh
        // round-trip; doing them on MainActor would beach-ball for ~1s.
        Task.detached { [weak self] in
            let cfg = svc.loadConfig()
            let gw = svc.loadGatewayState()
            let running = svc.isHermesRunning()
            let raw = ctx.readText(ctx.paths.configYAML)
            if raw == nil {
                log.error("Failed to read config.yaml from \(displayName)")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.config = cfg
                self.gatewayState = gw
                self.hermesRunning = running
                self.rawConfigYAML = raw ?? ""
                self.personalities = self.parsePersonalities()
                self.isLoading = false
            }
        }
    }

    /// Set a scalar config value via `hermes config set <key> <value>` and reload
    /// the config on success so the UI reflects the new state.
    func setSetting(_ key: String, value: String) {
        applyConfigWrite(key, arguments: ["config", "set", key, value])
    }

    /// Remove a config key entirely via `hermes config unset <key>`.
    ///
    /// This is NOT the same as `setSetting(key, value: "")`. `hermes config
    /// set <key> ""` writes an empty scalar, and for several keys Hermes
    /// distinguishes "key present but empty" from "key absent" — most
    /// visibly `browser.cloud_provider`, where a present-but-empty value
    /// normalizes to `local` (cloud dispatch off) while an absent key means
    /// auto-detect. Use this whenever a picker offers a "not set" row.
    func unsetSetting(_ key: String) {
        applyConfigWrite(key, arguments: ["config", "unset", key])
    }

    private func applyConfigWrite(_ key: String, arguments: [String]) {
        let result = runHermes(arguments)
        Analytics.record(.settingChanged(
            key: .init(rawKey: key),
            outcome: .init(succeeded: result.exitCode == 0)
        ))
        if result.exitCode == 0 {
            saveMessage = String(localized: "Saved \(key)")
            config = fileService.loadConfig()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveMessage = nil
            }
        } else {
            // `arguments` is a `hermes config set <key> <value>` — the value
            // is whatever the user typed into a settings field, which
            // includes API keys, tokens and endpoint credentials, and
            // `result.output` echoes the offending value back. Neither
            // belongs in a log anyone with Console.app can read. The
            // decision and the key stay `.public` so the line is still
            // useful; the payload is `.private`. Matches the shape of the
            // CronViewModel fix in F2 — this was its surviving sibling. (F9)
            logger.warning(
                "hermes config command failed: key=\(key, privacy: .public) exit=\(result.exitCode, privacy: .public) args=\(arguments, privacy: .private) output=\(result.output, privacy: .private)"
            )
            saveMessage = Self.saveFailureMessage(key: key, output: result.output)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.saveMessage = nil
            }
        }
    }

    /// Build the user-visible failure banner for a `hermes config set/unset`
    /// that exited non-zero, surfacing the CLI's own reason instead of a
    /// generic failure — e.g. "Cannot set '<key>': it is managed by your
    /// administrator" when the key is pinned under managed scope
    /// (`/etc/hermes`), so the user understands why the control snapped back.
    ///
    /// Taking the literal last line is not enough on v0.21+. Its new
    /// phantom-sibling guard (`hermes_cli/config.py:_set_nested`) raises a
    /// bare `ValueError` that `hermes config set` does NOT catch — its
    /// handler only catches `RuntimeError` — so the whole thing reaches us as
    /// a Python traceback. So: scan upward for the last line that isn't blank
    /// and isn't an indented traceback frame, then strip the leading
    /// exception-class label and Hermes's own `✗ ` marker.
    ///
    /// `static` and `internal` so tests can drive it with fixture output
    /// without standing up a SettingsViewModel.
    static func saveFailureMessage(key: String, output: String) -> String {
        let reason = Self.failureReason(from: output) ?? ""
        return reason.isEmpty
            ? String(localized: "Failed to save \(key)")
            : String(localized: "Couldn’t save \(key): \(reason)")
    }

    /// The extraction half of `saveFailureMessage`, without the "save"
    /// wording — for channels that report an *action* rather than a write
    /// (gateway start/stop/restart). Returns `nil` when the CLI said
    /// nothing usable, so the caller can pick its own generic sentence.
    static func failureReason(from output: String) -> String? {
        let reason = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { line in
                guard !line.isEmpty else { return false }
                // Traceback scaffolding, never the message itself.
                if line.hasPrefix("Traceback (most recent call last)") { return false }
                if line.hasPrefix("File \"") { return false }
                return true
            }
            .map(Self.strippingErrorDecoration) ?? ""
        return reason.isEmpty ? nil : reason
    }

    /// Strip Hermes's `✗ ` CLI marker and any leading `SomeError: ` label
    /// that a raw Python traceback tail carries, so the banner shows the
    /// sentence rather than the plumbing.
    nonisolated private static func strippingErrorDecoration(_ line: String) -> String {
        var text = line
        if text.hasPrefix("✗") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // `ValueError: Refusing to create nested key …` → drop the label.
        // Only for an unspaced CamelCase identifier ending in Error/Exception,
        // so a legitimate message containing a colon is left intact.
        if let colon = text.firstIndex(of: ":") {
            let label = String(text[text.startIndex..<colon])
            let isErrorLabel = !label.isEmpty
                && (label.hasSuffix("Error") || label.hasSuffix("Exception"))
                && label.first?.isUppercase == true
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
            if isErrorLabel {
                let rest = text[text.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { text = rest }
            }
        }
        return text
    }

    // MARK: - Analytics

    /// Sanitizes a `hermes config set/unset` key for `setting_changed`'s
    /// `key` prop — the identifier only, never the value being set (that
    /// requirement is enforced structurally: `applyConfigWrite` never sees
    /// the value at all here, only `key`).
    ///
    /// Every `setSetting`/`unsetSetting` call site in this file passes a
    /// literal dotted path (`"display.streaming"`, `"model.default"`, …)
    /// except `setAuxiliary(_:field:value:)`, which interpolates a `task`
    /// and `field` into `"auxiliary.<task>.<field>"` — checked against
    /// `AuxiliaryTab.swift`, both come from that view's fixed task/field
    /// pickers, never a text field, so today every key is already a
    /// bounded-cardinality token. This sanitizer is defense-in-depth
    /// against that assumption breaking in the future rather than a fix
    /// for a leak that exists today: it caps to the first three
    /// dot-segments (covers every current key shape, including the
    /// three-level auxiliary keys). Each segment is kept **only** if it's
    /// already a short bounded-cardinality token (`[a-z0-9_]`, ≤40 chars,
    /// case-insensitive) — anything else collapses to a fixed opaque
    /// placeholder rather than being character-filtered in place: filtering
    /// disallowed characters out of e.g. `/Users/someone/secret.txt` still
    /// leaves `Userssomeonesecrettxt`, and "someone" surviving as a
    /// substring is exactly the leak this exists to prevent. All-or-nothing
    /// per segment is the only shape that can't leak a fragment.
    nonisolated static func analyticsSettingKey(_ key: String) -> String {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false).prefix(3)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        let cleaned = segments.map { segment -> String in
            let lowered = segment.lowercased()
            guard !lowered.isEmpty, lowered.count <= 40,
                  lowered.unicodeScalars.allSatisfy(allowed.contains) else {
                return "unknown"
            }
            return lowered
        }
        return cleaned.joined(separator: ".")
    }

    // MARK: - Model

    func setModel(_ value: String) { setSetting("model.default", value: value) }
    func setProvider(_ value: String) { setSetting("model.provider", value: value) }

    /// Persist a model-picker selection through `LocalModelConfigPlan` —
    /// the one place that owns the write contract (which keys a local
    /// provider writes, and the clear-on-switch rule that scrubs stale
    /// `model.base_url`/`model.api_key`/`model.api_mode` on any provider
    /// change). `local` is non-nil when the user picked from the Local
    /// tab; nil is the classic remote/catalog path.
    ///
    /// Runs detached: the plan is up to six sequential `hermes config
    /// set` calls — blocking SSH round-trips on remote contexts that
    /// would beach-ball the MainActor (same rationale as `load`).
    func applyModelPickerSelection(model: String, provider: String, local: LocalModelSelection?) {
        let ops: [LocalModelConfigPlan.Operation]
        if let local {
            ops = LocalModelConfigPlan.operations(selecting: local)
        } else {
            // The HermesConfig overload maps the current local-key
            // values: a key that's already empty/absent is skipped
            // rather than re-cleared, so a never-local user keeps the
            // classic two-op write.
            ops = LocalModelConfigPlan.operations(
                selectingRemoteModel: model,
                provider: provider,
                current: config
            )
        }
        guard !ops.isEmpty else { return }
        let svc = fileService
        Task.detached { [weak self] in
            let ok = svc.applyModelConfigPlan(ops)
            let cfg = svc.loadConfig()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.config = cfg
                // `applyModelConfigPlan` reports only a Bool, so there is no
                // CLI reason to surface — but route through the shared
                // builder anyway so this banner keeps matching its siblings
                // if the wording ever changes.
                self.saveMessage = ok
                    ? String(localized: "Saved model settings")
                    : Self.saveFailureMessage(key: "model settings", output: "")
                DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 2 : 5)) { [weak self] in
                    self?.saveMessage = nil
                }
            }
        }
    }
    func setTimezone(_ value: String) { setSetting("timezone", value: value) }

    // MARK: - Display

    func setPersonality(_ value: String) { setSetting("display.personality", value: value) }
    func setStreaming(_ value: Bool) { setSetting("display.streaming", value: value ? "true" : "false") }
    func setShowReasoning(_ value: Bool) { setSetting("display.show_reasoning", value: value ? "true" : "false") }
    func setShowCost(_ value: Bool) { setSetting("display.show_cost", value: value ? "true" : "false") }
    func setInterimAssistantMessages(_ value: Bool) { setSetting("display.interim_assistant_messages", value: value ? "true" : "false") }
    func setSkin(_ value: String) { setSetting("display.skin", value: value) }
    func setDisplayCompact(_ value: Bool) { setSetting("display.compact", value: value ? "true" : "false") }
    func setResumeDisplay(_ value: String) { setSetting("display.resume_display", value: value) }
    func setBellOnComplete(_ value: Bool) { setSetting("display.bell_on_complete", value: value ? "true" : "false") }
    func setInlineDiffs(_ value: Bool) { setSetting("display.inline_diffs", value: value ? "true" : "false") }
    func setToolProgressCommand(_ value: Bool) { setSetting("display.tool_progress_command", value: value ? "true" : "false") }
    func setToolPreviewLength(_ value: Int) { setSetting("display.tool_preview_length", value: String(value)) }
    func setBusyInputMode(_ value: String) { setSetting("display.busy_input_mode", value: value) }
    /// v0.13: `display.language` for static-message translations. Empty
    /// string writes "" via `hermes config set` which Hermes treats as
    /// "use default"; explicit codes pin the language.
    func setDisplayLanguage(_ value: String) { setSetting("display.language", value: value) }
    /// v0.14: `display.timestamps` toggle for per-message timestamps
    /// in TUI output. Capability-gated in the UI on
    /// `HermesCapabilities.hasDisplayTimestamps`; this setter is safe
    /// to call against pre-v0.14 hosts (Hermes ignores unknown keys).
    func setDisplayTimestamps(_ value: Bool) { setSetting("display.timestamps", value: value ? "true" : "false") }

    // MARK: - Agent

    func setMaxTurns(_ value: Int) { setSetting("agent.max_turns", value: String(value)) }
    func setReasoningEffort(_ value: String) { setSetting("agent.reasoning_effort", value: value) }
    func setServiceTier(_ value: String) { setSetting("agent.service_tier", value: value) }
    func setGatewayNotifyInterval(_ value: Int) { setSetting("agent.gateway_notify_interval", value: String(value)) }
    func setGatewayTimeout(_ value: Int) { setSetting("agent.gateway_timeout", value: String(value)) }
    // -- v0.20.4+ (isV0204OrLater).
    func setCronDrainTimeout(_ value: Int) { setSetting("agent.cron_drain_timeout", value: String(value)) }
    func setGatewayTurnLeaseTimeout(_ value: Int) { setSetting("agent.gateway_turn_lease_timeout", value: String(value)) }
    func setToolUseEnforcement(_ value: String) { setSetting("agent.tool_use_enforcement", value: value) }
    func setApprovalMode(_ value: String) { setSetting("approvals.mode", value: value) }
    func setApprovalTimeout(_ value: Int) { setSetting("approvals.timeout", value: String(value)) }
    /// `approvals.smart_policy` (v0.20+) — free-text policy appended to the
    /// smart-approval guardian's system prompt. Empty writes an empty
    /// scalar ("no extra policy"), matching Hermes's own default; this is
    /// NOT the same as unsetting the key, but for a free-text policy field
    /// the two behave identically (Hermes treats an absent key and an
    /// empty string the same way — both mean "no extra policy").
    func setApprovalSmartPolicy(_ value: String) { setSetting("approvals.smart_policy", value: value) }

    // MARK: - Terminal

    func setTerminalBackend(_ value: String) { setSetting("terminal.backend", value: value) }
    func setTerminalCwd(_ value: String) { setSetting("terminal.cwd", value: value) }
    func setTerminalTimeout(_ value: Int) { setSetting("terminal.timeout", value: String(value)) }
    func setPersistentShell(_ value: Bool) { setSetting("terminal.persistent_shell", value: value ? "true" : "false") }
    func setDockerImage(_ value: String) { setSetting("terminal.docker_image", value: value) }
    func setDockerMountCwd(_ value: Bool) { setSetting("terminal.docker_mount_cwd_to_workspace", value: value ? "true" : "false") }
    /// v0.14: `terminal.docker_extra_args` — extra args forwarded
    /// verbatim to `docker run`. The picker accepts a comma-separated
    /// list; the setter splits + trims + writes a YAML list. Empty
    /// input drops the key (Hermes default applies).
    func setDockerExtraArgs(_ rawCSV: String) {
        let items = rawCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let yaml = items.isEmpty ? "[]" : "[" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        setSetting("terminal.docker_extra_args", value: yaml)
    }
    func setContainerCPU(_ value: Int) { setSetting("terminal.container_cpu", value: String(value)) }
    func setContainerMemory(_ value: Int) { setSetting("terminal.container_memory", value: String(value)) }
    func setContainerDisk(_ value: Int) { setSetting("terminal.container_disk", value: String(value)) }
    func setContainerPersistent(_ value: Bool) { setSetting("terminal.container_persistent", value: value ? "true" : "false") }
    func setModalImage(_ value: String) { setSetting("terminal.modal_image", value: value) }
    func setModalMode(_ value: String) { setSetting("terminal.modal_mode", value: value) }
    func setDaytonaImage(_ value: String) { setSetting("terminal.daytona_image", value: value) }
    func setSingularityImage(_ value: String) { setSetting("terminal.singularity_image", value: value) }

    // MARK: - Browser

    /// Writes `browser.cloud_provider`. The empty selection removes the key
    /// rather than writing `""` — Hermes' `_get_cloud_provider()` branches on
    /// `"cloud_provider" in browser_cfg`, so a present-but-empty value
    /// normalizes to `local` and silently disables cloud dispatch, which is
    /// not what "auto-detect" means.
    func setBrowserCloudProvider(_ value: String) {
        if value.isEmpty {
            unsetSetting("browser.cloud_provider")
        } else {
            setSetting("browser.cloud_provider", value: value)
        }
    }
    func setBrowserInactivityTimeout(_ value: Int) { setSetting("browser.inactivity_timeout", value: String(value)) }
    func setBrowserCommandTimeout(_ value: Int) { setSetting("browser.command_timeout", value: String(value)) }
    func setBrowserRecordSessions(_ value: Bool) { setSetting("browser.record_sessions", value: value ? "true" : "false") }
    func setBrowserAllowPrivateURLs(_ value: Bool) { setSetting("browser.allow_private_urls", value: value ? "true" : "false") }
    func setCamofoxManagedPersistence(_ value: Bool) { setSetting("browser.camofox.managed_persistence", value: value ? "true" : "false") }

    // MARK: - Web Tools

    /// Pre-v0.13 combined backend. Pre-v0.13 hosts read this; v0.13+
    /// hosts read it for back-compat but the WebToolsTab gates writes
    /// on `hasWebToolsBackendSplit` so the tab only writes the split
    /// keys on v0.13.
    // Hermes reads the `web:` block (tools/web_tools.py `_load_web_config()`):
    // `web.backend` (shared fallback), `web.search_backend` / `web.extract_backend`
    // (per-capability overrides). Scarf wrote `web_tools.*` until the v0.18 audit
    // caught it — `config set` accepts any dotted key, so those writes landed in
    // config.yaml as dead keys Hermes never read (silent no-op since ≤ v0.9).
    func setWebToolsBackend(_ value: String) { setSetting("web.backend", value: value) }
    func setWebToolsSearchBackend(_ value: String) { setSetting("web.search_backend", value: value) }
    func setWebToolsExtractBackend(_ value: String) { setSetting("web.extract_backend", value: value) }

    // MARK: - Voice / TTS / STT

    func setAutoTTS(_ value: Bool) { setSetting("voice.auto_tts", value: value ? "true" : "false") }
    func setSilenceThreshold(_ value: Int) { setSetting("voice.silence_threshold", value: String(value)) }
    func setRecordKey(_ value: String) { setSetting("voice.record_key", value: value) }
    func setMaxRecordingSeconds(_ value: Int) { setSetting("voice.max_recording_seconds", value: String(value)) }
    func setSilenceDuration(_ value: Double) { setSetting("voice.silence_duration", value: String(value)) }
    func setTTSProvider(_ value: String) { setSetting("tts.provider", value: value) }
    func setTTSEdgeVoice(_ value: String) { setSetting("tts.edge.voice", value: value) }
    func setTTSElevenLabsVoiceID(_ value: String) { setSetting("tts.elevenlabs.voice_id", value: value) }
    func setTTSElevenLabsModelID(_ value: String) { setSetting("tts.elevenlabs.model_id", value: value) }
    func setTTSOpenAIModel(_ value: String) { setSetting("tts.openai.model", value: value) }
    func setTTSOpenAIVoice(_ value: String) { setSetting("tts.openai.voice", value: value) }
    func setTTSNeuTTSModel(_ value: String) { setSetting("tts.neutts.model", value: value) }
    func setTTSNeuTTSDevice(_ value: String) { setSetting("tts.neutts.device", value: value) }
    // v0.13: xAI TTS / Custom Voices. TODO(WS-8-Q2): grep-verify key
    // names against `~/.hermes/hermes-agent/hermes_cli/voice/tts.py`.
    func setTTSXAIVoiceID(_ value: String) { setSetting("tts.xai.voice_id", value: value) }
    // v0.15: auto-insert speech-control tags into xAI TTS output.
    func setTTSXAIAutoSpeechTags(_ value: Bool) { setSetting("tts.xai.auto_speech_tags", value: value ? "true" : "false") }
    // -- xAI TTS advanced params (v0.19+, hasXAITTSAdvancedParams).
    func setTTSXAILanguage(_ value: String) { setSetting("tts.xai.language", value: value) }
    func setTTSXAISpeed(_ value: Double) { setSetting("tts.xai.speed", value: String(value)) }
    func setTTSXAIOptimizeStreamingLatency(_ value: Int) { setSetting("tts.xai.optimize_streaming_latency", value: String(value)) }
    func setTTSXAISampleRate(_ value: Int) { setSetting("tts.xai.sample_rate", value: String(value)) }
    func setTTSXAIBitRate(_ value: Int) { setSetting("tts.xai.bit_rate", value: String(value)) }
    // -- DeepInfra TTS (v0.19+, hasDeepInfraTTS).
    func setTTSDeepInfraModel(_ value: String) { setSetting("tts.deepinfra.model", value: value) }
    func setTTSDeepInfraVoice(_ value: String) { setSetting("tts.deepinfra.voice", value: value) }
    func setSTTEnabled(_ value: Bool) { setSetting("stt.enabled", value: value ? "true" : "false") }
    /// Writes `stt.provider`. The empty selection removes the key rather than
    /// writing `""` — on v0.20.5+ an absent key is the autodetect ladder while
    /// a present value (empty included) is an explicit pin.
    func setSTTProvider(_ value: String) {
        if value.isEmpty {
            unsetSetting("stt.provider")
        } else {
            setSetting("stt.provider", value: value)
        }
    }
    func setSTTLocalModel(_ value: String) { setSetting("stt.local.model", value: value) }
    func setSTTLocalLanguage(_ value: String) { setSetting("stt.local.language", value: value) }
    func setSTTOpenAIModel(_ value: String) { setSetting("stt.openai.model", value: value) }
    func setSTTOpenAILanguage(_ value: String) { setSetting("stt.openai.language", value: value) }
    func setSTTMistralModel(_ value: String) { setSetting("stt.mistral.model", value: value) }
    // -- Global STT language hint + Groq knobs (v0.20+, hasSTTUnifiedLanguage).
    func setSTTLanguage(_ value: String) { setSetting("stt.language", value: value) }
    func setSTTGroqModel(_ value: String) { setSetting("stt.groq.model", value: value) }
    func setSTTGroqLanguage(_ value: String) { setSetting("stt.groq.language", value: value) }
    // -- Local STT VAD anti-hallucination tuning (v0.20+, hasSTTLocalVADTuning).
    func setSTTLocalVAD(_ value: Bool) { setSetting("stt.local.vad", value: value ? "true" : "false") }
    func setSTTLocalVADMinSilenceMS(_ value: Int) { setSetting("stt.local.vad_min_silence_ms", value: String(value)) }
    func setSTTLocalNoSpeechProbThreshold(_ value: Double) { setSetting("stt.local.no_speech_prob_threshold", value: String(value)) }
    func setSTTLocalLogprobThreshold(_ value: Double) { setSetting("stt.local.logprob_threshold", value: String(value)) }
    // -- v0.20.4+ (isV0204OrLater).
    func setSTTLocalUnloadAfterIdleSeconds(_ value: Int) { setSetting("stt.local.unload_after_idle_seconds", value: String(value)) }
    /// `stt.cloud_trim_silence` / `stt.cloud_trim_threshold_db` /
    /// `stt.cloud_trim_keep_ms` — TOP-LEVEL siblings of `stt.local.*`.
    func setSTTCloudTrimSilence(_ value: Bool) { setSetting("stt.cloud_trim_silence", value: value ? "true" : "false") }
    func setSTTCloudTrimThresholdDB(_ value: Double) { setSetting("stt.cloud_trim_threshold_db", value: String(value)) }
    func setSTTCloudTrimKeepMS(_ value: Int) { setSetting("stt.cloud_trim_keep_ms", value: String(value)) }
    /// `wake_word.capture` — `auto` | `local` | `client`.
    func setWakeWordCapture(_ value: String) { setSetting("wake_word.capture", value: value) }

    // MARK: - Memory

    func setMemoryEnabled(_ value: Bool) { setSetting("memory.memory_enabled", value: value ? "true" : "false") }
    func setUserProfileEnabled(_ value: Bool) { setSetting("memory.user_profile_enabled", value: value ? "true" : "false") }
    func setMemoryCharLimit(_ value: Int) { setSetting("memory.memory_char_limit", value: String(value)) }
    func setUserCharLimit(_ value: Int) { setSetting("memory.user_char_limit", value: String(value)) }
    func setNudgeInterval(_ value: Int) { setSetting("memory.nudge_interval", value: String(value)) }
    /// Provider switching for external memory plugins. Uses `hermes memory setup/off`
    /// because the CLI wizard runs provider-specific init steps beyond a simple
    /// config.yaml write.
    ///
    /// The `off` branch is NOT a `hermes config set`, so it can't ride
    /// `applyConfigWrite`; it still has to surface a non-zero exit the same
    /// way — a failed teardown used to reload the unchanged config and
    /// present as a silent success, leaving the picker showing "none" while
    /// the provider was still wired up.
    func setMemoryProvider(_ value: String) {
        guard value.isEmpty else {
            setSetting("memory.provider", value: value)
            return
        }
        let key = "memory.provider"
        let result = runHermes(["memory", "off"])
        Analytics.record(.settingChanged(
            key: .init(rawKey: key),
            outcome: .init(succeeded: result.exitCode == 0)
        ))
        config = fileService.loadConfig()
        if result.exitCode == 0 {
            saveMessage = String(localized: "Saved \(key)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveMessage = nil
            }
        } else {
            logger.warning("hermes memory off failed (exit \(result.exitCode)): \(result.output)")
            saveMessage = Self.saveFailureMessage(key: key, output: result.output)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.saveMessage = nil
            }
        }
    }
    // Hermes v0.9.0 PR #6995: the key is camelCase in config.yaml (not snake_case like the rest of Hermes).
    func setHonchoInitOnSessionStart(_ value: Bool) { setSetting("honcho.initOnSessionStart", value: value ? "true" : "false") }

    // MARK: - Auxiliary model sub-tasks

    func setAuxiliary(_ task: String, field: String, value: String) {
        setSetting("auxiliary.\(task).\(field)", value: value)
    }
    func setAuxiliaryTimeout(_ task: String, value: Int) {
        setSetting("auxiliary.\(task).timeout", value: String(value))
    }
    /// `auxiliary.<task>.reasoning_effort` (v0.19+, capability-gated by the
    /// caller on `hasAuxiliaryReasoningEffort`). `""` means "unset — inherit
    /// provider default", matching Hermes's own default value for this
    /// field (config_defaults.py has every task default to `""`), so
    /// writing an empty scalar here is safe and behaves the same as an
    /// absent key — this is NOT one of the empty-vs-unset hazard keys.
    /// Valid non-empty values: `AuxiliaryReasoningEffort.allCases`.
    func setAuxiliaryReasoningEffort(_ task: String, value: String) {
        setSetting("auxiliary.\(task).reasoning_effort", value: value)
    }
    /// `auxiliary.<task>.max_concurrency` (v0.20.4+, isV0204OrLater) —
    /// true-optional cap on simultaneous calls for that task. Currently
    /// only surfaced for `compression`. Empty clears back to unlimited.
    func setAuxiliaryMaxConcurrency(_ task: String, value: Int?) {
        if let value {
            setSetting("auxiliary.\(task).max_concurrency", value: String(value))
        } else {
            unsetSetting("auxiliary.\(task).max_concurrency")
        }
    }
    /// `auxiliary.background_review.enabled` (v0.20.4+, isV0204OrLater) —
    /// NOT `agent.background_review.enabled`; nested under the top-level
    /// `auxiliary:` block. On by default; post-turn self-improvement fork
    /// that runs after nudge intervals fire — costs tokens. `false` skips
    /// automatic forks (`/refine` still works).
    func setBackgroundReviewEnabled(_ value: Bool) {
        setSetting("auxiliary.background_review.enabled", value: value ? "true" : "false")
    }

    // MARK: - Title generation (auxiliary.title_generation)

    /// `auxiliary.title_generation.enabled` — title generation predates
    /// Hermes's calendar-version scheme, so this is ungated (unlike the
    /// `language` field below).
    func setTitleGenerationEnabled(_ value: Bool) {
        setSetting("auxiliary.title_generation.enabled", value: value ? "true" : "false")
    }
    func setTitleGeneration(field: String, value: String) {
        setSetting("auxiliary.title_generation.\(field)", value: value)
    }
    func setTitleGenerationTimeout(_ value: Int) {
        setSetting("auxiliary.title_generation.timeout", value: String(value))
    }
    /// `auxiliary.title_generation.reasoning_effort` (v0.19+, same
    /// empty-is-default semantics as `setAuxiliaryReasoningEffort`).
    func setTitleGenerationReasoningEffort(_ value: String) {
        setSetting("auxiliary.title_generation.reasoning_effort", value: value)
    }
    /// `auxiliary.title_generation.language` (v0.18+, capability-gated by
    /// the caller on `hasTitleGenerationLanguage`). Empty means "match the
    /// chat's own language" (Hermes default).
    func setTitleGenerationLanguage(_ value: String) {
        setSetting("auxiliary.title_generation.language", value: value)
    }
    /// `auxiliary.title_generation.max_concurrency` (v0.20.4+,
    /// isV0204OrLater) — true-optional cap on simultaneous title calls.
    func setTitleGenerationMaxConcurrency(_ value: Int?) {
        if let value {
            setSetting("auxiliary.title_generation.max_concurrency", value: String(value))
        } else {
            unsetSetting("auxiliary.title_generation.max_concurrency")
        }
    }

    // MARK: - Image generation (v0.13+)

    /// `image_gen.model` — overrides the per-provider default image
    /// model (Hermes v0.13+). Empty string clears the override.
    /// Capability-gated in `AuxiliaryTab` so pre-v0.13 hosts never
    /// invoke this setter.
    func setImageGenModel(_ value: String) { setSetting("image_gen.model", value: value) }

    /// `openrouter.response_cache` — toggles OpenRouter response caching
    /// for repeat prompts. Hermes v0.16 reads this as a SCALAR bool
    /// directly under `openrouter:` (writing the nested `.enabled` shape
    /// would be read as a truthy dict, so disabling it would silently
    /// stay on). Capability-gated in `AuxiliaryTab` so pre-v0.13 hosts
    /// never invoke this setter. Keep in lockstep with the parser line in
    /// `HermesConfig+YAML.swift`.
    func setOpenRouterResponseCache(_ value: Bool) {
        setSetting("openrouter.response_cache", value: value ? "true" : "false")
    }

    // MARK: - Security / Privacy

    func setRedactSecrets(_ value: Bool) { setSetting("security.redact_secrets", value: value ? "true" : "false") }
    func setRedactPII(_ value: Bool) { setSetting("privacy.redact_pii", value: value ? "true" : "false") }
    func setTirithEnabled(_ value: Bool) { setSetting("security.tirith_enabled", value: value ? "true" : "false") }
    func setTirithPath(_ value: String) { setSetting("security.tirith_path", value: value) }
    func setTirithTimeout(_ value: Int) { setSetting("security.tirith_timeout", value: String(value)) }
    func setTirithFailOpen(_ value: Bool) { setSetting("security.tirith_fail_open", value: value ? "true" : "false") }
    func setBlocklistEnabled(_ value: Bool) { setSetting("security.website_blocklist.enabled", value: value ? "true" : "false") }
    func setHumanDelayMode(_ value: String) { setSetting("human_delay.mode", value: value) }
    func setHumanDelayMinMS(_ value: Int) { setSetting("human_delay.min_ms", value: String(value)) }
    func setHumanDelayMaxMS(_ value: Int) { setSetting("human_delay.max_ms", value: String(value)) }

    // MARK: - Secrets (Bitwarden Secrets Manager, v0.15)

    func setBitwardenEnabled(_ value: Bool) { setSetting("secrets.bitwarden.enabled", value: value ? "true" : "false") }
    func setBitwardenAccessTokenEnv(_ value: String) { setSetting("secrets.bitwarden.access_token_env", value: value) }
    func setBitwardenProjectID(_ value: String) { setSetting("secrets.bitwarden.project_id", value: value) }
    func setBitwardenOverrideExisting(_ value: Bool) { setSetting("secrets.bitwarden.override_existing", value: value ? "true" : "false") }
    func setBitwardenServerURL(_ value: String) { setSetting("secrets.bitwarden.server_url", value: value) }
    func setBitwardenCacheTTLSeconds(_ value: Int) { setSetting("secrets.bitwarden.cache_ttl_seconds", value: String(value)) }
    func setBitwardenAutoInstall(_ value: Bool) { setSetting("secrets.bitwarden.auto_install", value: value ? "true" : "false") }

    /// `secrets.bitwarden.encrypted_cache.*` (v0.20+, gated by the caller
    /// on `hasBitwardenEncryptedCache`). `max_stale_seconds` default is a
    /// real `0` ("no stale fallback"), not an unset sentinel — plain
    /// scalar write, no unset machinery needed.
    func setBitwardenEncryptedCacheEnabled(_ value: Bool) { setSetting("secrets.bitwarden.encrypted_cache.enabled", value: value ? "true" : "false") }
    func setBitwardenEncryptedCacheMaxStaleSeconds(_ value: Int) { setSetting("secrets.bitwarden.encrypted_cache.max_stale_seconds", value: String(value)) }

    // MARK: - Secrets (command helper, v0.20+)

    /// `secrets.command.*` — any-CLI vault helper secret source (v0.20+,
    /// gated by the caller on `hasCommandSecretSource`). `command` is run
    /// via `/bin/sh -c` with the same trust level as the user's own
    /// `.env` file — see `CommandSecretsSettings` doc.
    func setCommandSecretsEnabled(_ value: Bool) { setSetting("secrets.command.enabled", value: value ? "true" : "false") }
    func setCommandSecretsCommand(_ value: String) { setSetting("secrets.command.command", value: value) }
    func setCommandSecretsHelperTimeoutSeconds(_ value: Double) { setSetting("secrets.command.helper_timeout_seconds", value: String(value)) }
    func setCommandSecretsOverrideExisting(_ value: Bool) { setSetting("secrets.command.override_existing", value: value ? "true" : "false") }

    // MARK: - Telemetry (v0.20+)

    /// `telemetry.shared_metrics.enabled` — privacy-safe opt-in local
    /// aggregate metrics; no remote sink. Gated by the caller on
    /// `hasSharedMetricsTelemetry`.
    func setSharedMetricsEnabled(_ value: Bool) { setSetting("telemetry.shared_metrics.enabled", value: value ? "true" : "false") }

    // MARK: - Database (v0.20+)

    /// `database.journal_mode` — closed enum in practice (`wal`/`delete`;
    /// `hermes_state.resolve_journal_mode()` falls back to `wal` for
    /// anything else), so the UI offers a picker, not free text. Gated on
    /// `hasDatabaseJournalSettings`.
    func setDatabaseJournalMode(_ value: String) { setSetting("database.journal_mode", value: value) }

    /// `database.wal_autocheckpoint` (pages) — true optional. `nil` clears
    /// the key via `unsetSetting` (SQLite default: 1000-page
    /// autocheckpoint); a concrete value, including `0`, writes a scalar.
    /// Do NOT collapse this to an empty-string write — `0` and "absent"
    /// are different Hermes behaviors here.
    func setDatabaseWalAutocheckpoint(_ value: Int?) {
        if let value {
            setSetting("database.wal_autocheckpoint", value: String(value))
        } else {
            unsetSetting("database.wal_autocheckpoint")
        }
    }

    /// `database.journal_size_limit` (bytes) — true optional, same
    /// unset-vs-empty hazard as `setDatabaseWalAutocheckpoint`. `nil`
    /// clears the key (SQLite default: no limit).
    func setDatabaseJournalSizeLimit(_ value: Int?) {
        if let value {
            setSetting("database.journal_size_limit", value: String(value))
        } else {
            unsetSetting("database.journal_size_limit")
        }
    }

    /// `gateway.multiplex_profile_allowlist` (v0.20.4+) warning helper for
    /// `ProfileRoutesSection` — returns a user-facing message when
    /// `profile` would never be reachable at runtime even though a route
    /// targets it, or `nil` when there's nothing to warn about.
    ///
    /// Semantics (source-verified against gateway/config.py
    /// `_normalize_multiplex_profile_allowlist`): a `nil` allowlist means
    /// the key is absent — historical serve-all behavior, so every profile
    /// is reachable and no warning is ever shown. `"default"` is implicitly
    /// always allowed regardless of list contents, so it's exempted here
    /// even when the list doesn't literally contain it.
    func multiplexProfileAllowlistWarning(for profile: String) -> String? {
        guard let allowlist = config.multiplexProfileAllowlist else { return nil }
        if profile.isEmpty || profile == "default" { return nil }
        if allowlist.contains(profile) { return nil }
        return "Profile \"\(profile)\" is not in `gateway.multiplex_profile_allowlist` — Hermes will reject messages routed here."
    }

    /// Read-only status panel via `hermes secrets bitwarden status`. Mirrors
    /// how `runConfigCheck` shells a read; returns the captured text output
    /// (a Rich panel). Empty on non-zero exit.
    /// `async` — the CLI call is a process spawn (an SSH exec channel on a
    /// remote host) and ran inline on the MainActor from a button action,
    /// hanging Settings for the round-trip. The read itself is unchanged.
    func bitwardenStatus() async -> String {
        let ctx = context
        return await Task.detached { ctx.runHermes(["secrets", "bitwarden", "status"]).output }.value
    }

    // MARK: - Performance / Advanced

    func setForceIPv4(_ value: Bool) { setSetting("network.force_ipv4", value: value ? "true" : "false") }
    func setFileReadMaxChars(_ value: Int) { setSetting("file_read_max_chars", value: String(value)) }
    func setCompressionEnabled(_ value: Bool) { setSetting("compression.enabled", value: value ? "true" : "false") }
    func setCompressionThreshold(_ value: Double) { setSetting("compression.threshold", value: String(value)) }
    func setCompressionTargetRatio(_ value: Double) { setSetting("compression.target_ratio", value: String(value)) }
    func setCompressionProtectLastN(_ value: Int) { setSetting("compression.protect_last_n", value: String(value)) }
    // -- v0.20 compression tuning (UI gated on isV020OrLater). 0 is a
    // valid "off" write for threshold_tokens/idle_compact (Hermes treats
    // <= 0 as disabled), so plain scalar sets round-trip cleanly.
    func setCompressionThresholdTokens(_ value: Int) { setSetting("compression.threshold_tokens", value: String(value)) }
    func setCompressionMinTailUserMessages(_ value: Int) { setSetting("compression.min_tail_user_messages", value: String(value)) }
    func setCompressionIdleCompactAfterSeconds(_ value: Int) { setSetting("compression.idle_compact_after_seconds", value: String(value)) }
    func setCompressionProgressNotices(_ value: Bool) { setSetting("compression.progress_notices", value: value ? "true" : "false") }

    // MARK: v0.20 direct-YAML power settings

    /// Write `agent.reasoning_overrides` (dict — `hermes config set` can't).
    /// Refused silently on pre-v0.20 hosts (the UI is hidden there too).
    func saveReasoningOverrides(_ pairs: [(key: String, value: String)], capabilities: HermesCapabilities) {
        saveDirectYAML(label: "agent.reasoning_overrides") { yaml in
            PowerSettingsWriter.setReasoningOverrides(in: yaml, pairs: pairs, capabilities: capabilities)
        }
    }

    /// Write `model_catalog.excluded_providers` (list — `hermes config set`
    /// stringifies arrays). Refused silently on pre-v0.20 hosts.
    func saveExcludedProviders(_ providers: [String], capabilities: HermesCapabilities) {
        saveDirectYAML(label: "model_catalog.excluded_providers") { yaml in
            PowerSettingsWriter.setExcludedProviders(in: yaml, providers: providers, capabilities: capabilities)
        }
    }

    /// Write `profile_routes` (a list of MAPS — beyond both `hermes config
    /// set` and the scalar/flat-map direct-YAML writers). Refused silently
    /// on pre-v0.19 hosts, where the key didn't exist yet.
    ///
    /// `location` must come from the freshly-read config so the write lands
    /// in whichever of the two accepted forms Hermes actually reads
    /// (top-level wins over `gateway.` — gateway/config.py:1356).
    func saveProfileRoutes(
        _ routes: [HermesProfileRoute],
        location: HermesProfileRoutes.Location,
        capabilities: HermesCapabilities
    ) {
        saveDirectYAML(label: "profile_routes") { yaml in
            // Re-derive the live location from the YAML we are about to
            // edit rather than trusting the snapshot the view was rendered
            // from: Hermes (or a hand edit) may have moved the block since
            // the last load, and writing the wrong form would silently
            // shadow the user's edit.
            let live = ProfileRoutesYAML.parse(yaml).location
            return ProfileRoutesWriter.setProfileRoutes(
                in: yaml,
                routes: routes,
                location: live == .absent ? location : live,
                capabilities: capabilities
            )
        }
    }

    /// `gateway.multiplex_profiles` — the prerequisite for profile routing
    /// (gateway/run.py:23923 returns before matching when it's off). Plain
    /// scalar, so the CLI handles it.
    func setMultiplexProfiles(_ value: Bool) {
        setSetting("gateway.multiplex_profiles", value: value ? "true" : "false")
    }

    /// Shared read → transform → write → reload path for the direct-YAML
    /// writers, mirroring `GatewayConfigWriter.saveList`'s no-op-on-equal
    /// behavior and `setSetting`'s save toast.
    private func saveDirectYAML(label: String, transform: (String) -> String?) {
        let path = context.paths.configYAML
        let existing = context.readText(path) ?? ""
        guard let updated = transform(existing) else {
            // Writer refused (invalid value or capability-gated) — surface
            // it instead of silently dropping the save, mirroring the
            // write-failure toast below.
            saveMessage = "Could not save \(label): a value was rejected as invalid"
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.saveMessage = nil
            }
            return
        }
        if updated != existing {
            guard context.writeText(path, content: updated) else {
                // Direct-YAML write failure: no CLI output to quote, so the
                // shared builder's bare form is exactly right.
                saveMessage = Self.saveFailureMessage(key: label, output: "")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.saveMessage = nil
                }
                return
            }
        }
        saveMessage = String(localized: "Saved \(label)")
        config = fileService.loadConfig()
        rawConfigYAML = context.readText(path) ?? rawConfigYAML
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveMessage = nil
        }
    }
    func setCheckpointsEnabled(_ value: Bool) { setSetting("checkpoints.enabled", value: value ? "true" : "false") }
    func setCheckpointsMaxSnapshots(_ value: Int) { setSetting("checkpoints.max_snapshots", value: String(value)) }
    func setLoggingLevel(_ value: String) { setSetting("logging.level", value: value) }
    func setLoggingMaxSizeMB(_ value: Int) { setSetting("logging.max_size_mb", value: String(value)) }
    func setLoggingBackupCount(_ value: Int) { setSetting("logging.backup_count", value: String(value)) }
    func setDelegationModel(_ value: String) { setSetting("delegation.model", value: value) }
    func setDelegationProvider(_ value: String) { setSetting("delegation.provider", value: value) }
    func setDelegationBaseURL(_ value: String) { setSetting("delegation.base_url", value: value) }
    func setDelegationMaxIterations(_ value: Int) { setSetting("delegation.max_iterations", value: String(value)) }
    /// v0.20.4+ (isV0204OrLater) — server-side default 10, floor 1, no ceiling.
    func setDelegationMaxConcurrentChildren(_ value: Int) { setSetting("delegation.max_concurrent_children", value: String(value)) }
    func setCronWrapResponse(_ value: Bool) { setSetting("cron.wrap_response", value: value ? "true" : "false") }

    // MARK: - v0.17 config surfaces
    /// v0.17 — curator LLM consolidation pass (opt-in; deterministic pruning stays on).
    func setCuratorConsolidate(_ value: Bool) { setSetting("curator.consolidate", value: value ? "true" : "false") }
    /// v0.17 — cap on simultaneously-active chat sessions (0 = unbounded).
    func setMaxConcurrentSessions(_ value: Int) { setSetting("max_concurrent_sessions", value: String(value)) }

    // MARK: - Config diagnostics

    func runConfigCheck() -> String {
        let result = runHermes(["config", "check"])
        return result.output
    }

    func runConfigMigrate() -> String {
        let result = runHermes(["config", "migrate"])
        config = fileService.loadConfig()
        return result.output
    }

    // MARK: - Backup & Restore (v0.9.0)

    var backupInProgress = false

    func runBackup() {
        backupInProgress = true
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: ["backup"], timeout: 300)
            let zipPath = Self.extractZipPath(from: result.output)
            await MainActor.run {
                self.backupInProgress = false
                if result.exitCode == 0 {
                    if let zipPath {
                        // NSWorkspace operates on the *local* Mac's filesystem;
                        // a remote backup path doesn't exist here, so revealing
                        // it would silently no-op (or worse, reveal an
                        // unrelated local file with the same path). Surface the
                        // remote location in the saveMessage instead.
                        if self.context.isRemote {
                            self.saveMessage = "Backup saved on \(self.context.displayName): \(zipPath)"
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: zipPath)])
                            self.saveMessage = "Backup saved"
                        }
                    } else {
                        self.saveMessage = "Backup complete"
                    }
                } else {
                    self.saveMessage = "Backup failed"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.saveMessage = nil
                }
            }
        }
    }

    /// Restore from a backup `.zip`. The path may be local (the user picked
    /// it via `NSOpenPanel` on a local context) or remote (the user typed it
    /// in the remote-path sheet). Either way, the call goes through
    /// `fileService.runHermesCLI`, which is transport-aware — for an SSH
    /// context the `hermes import <path>` command runs on the remote shell
    /// where `<path>` is a remote filesystem path.
    func runRestore(fromPath path: String) {
        backupInProgress = true
        Task.detached { [fileService, self] in
            let result = fileService.runHermesCLI(args: ["import", path], timeout: 300)
            await MainActor.run {
                self.backupInProgress = false
                self.saveMessage = result.exitCode == 0 ? "Restore complete — restart Scarf" : "Restore failed"
                if result.exitCode == 0 {
                    self.load(force: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.saveMessage = nil
                }
            }
        }
    }

    /// Pull the first absolute `.zip` path out of `hermes backup` stdout.
    /// Hermes prints a line like "Backup saved to /Users/foo/.hermes-backups/hermes-2026-04-14.zip (5.4 MB)".
    nonisolated static func extractZipPath(from output: String) -> String? {
        let pattern = #"(/[^\s]+\.zip)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let r = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[r])
    }

    func openConfigInEditor() {
        // No-op for remote contexts — the file is on the remote host, not
        // this Mac. The Settings tab's in-app editor is the supported way
        // to edit remote configs.
        context.openInLocalEditor(context.paths.configYAML)
    }

    /// Picker options: the user entries under `agent.personalities`, plus
    /// Hermes' 14 built-ins on hosts that carry them in code (v0.20.4 moved
    /// them out of config.yaml into `hermes_cli/personality.py`). Pre-v0.20.4
    /// hosts ship the built-ins as editable YAML, so the config parse is
    /// authoritative there and a deleted entry stays deleted — see
    /// `HermesPersonalities.resolve`.
    private func parsePersonalities() -> [String] {
        HermesPersonalities.pickerOptions(
            yaml: rawConfigYAML,
            current: config.personality,
            hasBuiltinPersonalitiesInCode: hasBuiltinPersonalitiesInCode
        )
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }

    // MARK: - Allowlist suggestions (Hermes v0.20+, `hermes approvals suggest`)

    /// Proposals mined from approval history. Only populated on v0.20+
    /// hosts — the SecurityTab section that triggers `loadApprovalSuggestions`
    /// is capability-gated on `hasApprovalsSuggest`, so pre-0.20 hosts never
    /// issue the CLI call and never see the section.
    var approvalProposals: [HermesApprovalProposal] = []
    var isLoadingApprovalSuggestions = false
    /// Non-nil after a load attempt; distinguishes "no proposals" from
    /// "not loaded yet" so the empty state renders honestly.
    var approvalSuggestionsLoaded = false
    var approvalSuggestMessage: String?
    /// Proposal currently being applied (its `n`), to disable just that row's button.
    var applyingProposalN: Int?

    /// Run the read-only mining pass (`approvals suggest --json`). Never
    /// destructive — nothing is written without `--apply`.
    func loadApprovalSuggestions(force: Bool = false) {
        if isLoadingApprovalSuggestions { return }
        if approvalSuggestionsLoaded && !force { return }
        isLoadingApprovalSuggestions = true
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            let result = svc.runHermesCLISplit(args: HermesApprovalsSuggestParser.suggestArgs(), timeout: 60)
            let proposals = result.exitCode == 0 ? HermesApprovalsSuggestParser.parse(json: result.stdout) : nil
            if proposals == nil {
                log.warning("approvals suggest failed (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.approvalProposals = proposals ?? []
                self.approvalSuggestionsLoaded = true
                self.isLoadingApprovalSuggestions = false
                if proposals == nil {
                    self.approvalSuggestMessage = "Couldn't mine approval history."
                }
            }
        }
    }

    /// Apply exactly ONE proposal (`--apply <n>`). Writes to
    /// `command_allowlist` in config.yaml, so this only ever runs from an
    /// explicit per-proposal user click — no bulk apply exists by design.
    /// On success the config and the proposal list are both reloaded (the
    /// CLI re-numbers survivors, so stale `n` values must not be reused).
    func applyApprovalProposal(_ proposal: HermesApprovalProposal) {
        guard applyingProposalN == nil,
              let args = HermesApprovalsSuggestParser.applyArgs(indices: [proposal.n]) else { return }
        applyingProposalN = proposal.n
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            let result = svc.runHermesCLISplit(args: args, timeout: 60)
            let applied = result.exitCode == 0
                ? HermesApprovalsSuggestParser.parseApplyResult(json: result.stdout)
                : nil
            if applied == nil {
                log.warning("approvals suggest --apply \(proposal.n) failed (exit \(result.exitCode)): \(result.stderr.prefix(300))")
            }
            let cfg = applied != nil ? svc.loadConfig() : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyingProposalN = nil
                if let applied {
                    if let cfg { self.config = cfg }
                    self.approvalSuggestMessage =
                        "Added \(applied.applied.joined(separator: ", ")) — allowlist now \(applied.allowlistSize) entries"
                } else {
                    self.approvalSuggestMessage = "Apply failed: \(result.stderr.isEmpty ? result.stdout.prefix(200) : result.stderr.prefix(200))"
                }
                // Indices shift after an apply — always re-mine.
                self.loadApprovalSuggestions(force: true)
                // Compare-before-clear (same pattern as
                // MCPServersViewModel.statusMessage): a newer banner from a
                // subsequent apply must not be wiped by this one's timer.
                let shownMessage = self.approvalSuggestMessage
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard let self else { return }
                    if self.approvalSuggestMessage == shownMessage {
                        self.approvalSuggestMessage = nil
                    }
                }
            }
        }
    }
}
