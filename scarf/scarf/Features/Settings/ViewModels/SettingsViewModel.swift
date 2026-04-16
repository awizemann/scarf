import Foundation
import AppKit
import UniformTypeIdentifiers
import os

@Observable
final class SettingsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "SettingsViewModel")
    private let fileService = HermesFileService()

    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var rawConfigYAML = ""
    var personalities: [String] = []
    var providers = ["anthropic", "openrouter", "nous", "openai-codex", "google-ai-studio", "xai", "ollama-cloud", "zai", "kimi-coding", "minimax"]
    var terminalBackends = ["local", "docker", "singularity", "modal", "daytona", "ssh"]
    var browserBackends = ["browseruse", "firecrawl", "local"]
    var ttsProviders = ["edge", "elevenlabs", "openai", "minimax", "mistral", "neutts"]
    var sttProviders = ["local", "groq", "openai", "mistral"]
    var memoryProviders = ["", "honcho", "openviking", "mem0", "hindsight", "holographic", "retaindb", "byterover", "supermemory"]
    var saveMessage: String?

    func load() {
        config = fileService.loadConfig()
        gatewayState = fileService.loadGatewayState()
        hermesRunning = fileService.isHermesRunning()
        do {
            rawConfigYAML = try String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8)
        } catch {
            logger.error("Failed to read config.yaml: \(error.localizedDescription)")
            rawConfigYAML = ""
        }
        personalities = parsePersonalities()
    }

    /// Set a scalar config value via `hermes config set <key> <value>` and reload
    /// the config on success so the UI reflects the new state.
    func setSetting(_ key: String, value: String) {
        let result = runHermes(["config", "set", key, value])
        if result.exitCode == 0 {
            saveMessage = "Saved \(key)"
            config = fileService.loadConfig()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveMessage = nil
            }
        } else {
            logger.warning("hermes config set \(key) failed (exit \(result.exitCode)): \(result.output)")
            saveMessage = "Failed to save \(key)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.saveMessage = nil
            }
        }
    }

    // MARK: - Model

    func setModel(_ value: String) { setSetting("model.default", value: value) }
    func setProvider(_ value: String) { setSetting("model.provider", value: value) }
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

    // MARK: - Agent

    func setMaxTurns(_ value: Int) { setSetting("agent.max_turns", value: String(value)) }
    func setReasoningEffort(_ value: String) { setSetting("agent.reasoning_effort", value: value) }
    func setVerbose(_ value: Bool) { setSetting("agent.verbose", value: value ? "true" : "false") }
    func setServiceTier(_ value: String) { setSetting("agent.service_tier", value: value) }
    func setGatewayNotifyInterval(_ value: Int) { setSetting("agent.gateway_notify_interval", value: String(value)) }
    func setGatewayTimeout(_ value: Int) { setSetting("agent.gateway_timeout", value: String(value)) }
    func setToolUseEnforcement(_ value: String) { setSetting("agent.tool_use_enforcement", value: value) }
    func setApprovalMode(_ value: String) { setSetting("approvals.mode", value: value) }
    func setApprovalTimeout(_ value: Int) { setSetting("approvals.timeout", value: String(value)) }

    // MARK: - Terminal

    func setTerminalBackend(_ value: String) { setSetting("terminal.backend", value: value) }
    func setTerminalCwd(_ value: String) { setSetting("terminal.cwd", value: value) }
    func setTerminalTimeout(_ value: Int) { setSetting("terminal.timeout", value: String(value)) }
    func setPersistentShell(_ value: Bool) { setSetting("terminal.persistent_shell", value: value ? "true" : "false") }
    func setDockerImage(_ value: String) { setSetting("terminal.docker_image", value: value) }
    func setDockerMountCwd(_ value: Bool) { setSetting("terminal.docker_mount_cwd_to_workspace", value: value ? "true" : "false") }
    func setContainerCPU(_ value: Int) { setSetting("terminal.container_cpu", value: String(value)) }
    func setContainerMemory(_ value: Int) { setSetting("terminal.container_memory", value: String(value)) }
    func setContainerDisk(_ value: Int) { setSetting("terminal.container_disk", value: String(value)) }
    func setContainerPersistent(_ value: Bool) { setSetting("terminal.container_persistent", value: value ? "true" : "false") }
    func setModalImage(_ value: String) { setSetting("terminal.modal_image", value: value) }
    func setModalMode(_ value: String) { setSetting("terminal.modal_mode", value: value) }
    func setDaytonaImage(_ value: String) { setSetting("terminal.daytona_image", value: value) }
    func setSingularityImage(_ value: String) { setSetting("terminal.singularity_image", value: value) }

    // MARK: - Browser

    func setBrowserBackend(_ value: String) { setSetting("browser.backend", value: value) }
    func setBrowserInactivityTimeout(_ value: Int) { setSetting("browser.inactivity_timeout", value: String(value)) }
    func setBrowserCommandTimeout(_ value: Int) { setSetting("browser.command_timeout", value: String(value)) }
    func setBrowserRecordSessions(_ value: Bool) { setSetting("browser.record_sessions", value: value ? "true" : "false") }
    func setBrowserAllowPrivateURLs(_ value: Bool) { setSetting("browser.allow_private_urls", value: value ? "true" : "false") }
    func setCamofoxManagedPersistence(_ value: Bool) { setSetting("browser.camofox.managed_persistence", value: value ? "true" : "false") }

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
    func setSTTEnabled(_ value: Bool) { setSetting("stt.enabled", value: value ? "true" : "false") }
    func setSTTProvider(_ value: String) { setSetting("stt.provider", value: value) }
    func setSTTLocalModel(_ value: String) { setSetting("stt.local.model", value: value) }
    func setSTTLocalLanguage(_ value: String) { setSetting("stt.local.language", value: value) }
    func setSTTOpenAIModel(_ value: String) { setSetting("stt.openai.model", value: value) }
    func setSTTMistralModel(_ value: String) { setSetting("stt.mistral.model", value: value) }

    // MARK: - Memory

    func setMemoryEnabled(_ value: Bool) { setSetting("memory.memory_enabled", value: value ? "true" : "false") }
    func setUserProfileEnabled(_ value: Bool) { setSetting("memory.user_profile_enabled", value: value ? "true" : "false") }
    func setMemoryCharLimit(_ value: Int) { setSetting("memory.memory_char_limit", value: String(value)) }
    func setUserCharLimit(_ value: Int) { setSetting("memory.user_char_limit", value: String(value)) }
    func setNudgeInterval(_ value: Int) { setSetting("memory.nudge_interval", value: String(value)) }
    /// Provider switching for external memory plugins. Uses `hermes memory setup/off`
    /// because the CLI wizard runs provider-specific init steps beyond a simple
    /// config.yaml write.
    func setMemoryProvider(_ value: String) {
        if value.isEmpty {
            _ = runHermes(["memory", "off"])
        } else {
            setSetting("memory.provider", value: value)
        }
        config = fileService.loadConfig()
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

    // MARK: - Performance / Advanced

    func setForceIPv4(_ value: Bool) { setSetting("network.force_ipv4", value: value ? "true" : "false") }
    func setFileReadMaxChars(_ value: Int) { setSetting("file_read_max_chars", value: String(value)) }
    func setCompressionEnabled(_ value: Bool) { setSetting("compression.enabled", value: value ? "true" : "false") }
    func setCompressionThreshold(_ value: Double) { setSetting("compression.threshold", value: String(value)) }
    func setCompressionTargetRatio(_ value: Double) { setSetting("compression.target_ratio", value: String(value)) }
    func setCompressionProtectLastN(_ value: Int) { setSetting("compression.protect_last_n", value: String(value)) }
    func setCheckpointsEnabled(_ value: Bool) { setSetting("checkpoints.enabled", value: value ? "true" : "false") }
    func setCheckpointsMaxSnapshots(_ value: Int) { setSetting("checkpoints.max_snapshots", value: String(value)) }
    func setLoggingLevel(_ value: String) { setSetting("logging.level", value: value) }
    func setLoggingMaxSizeMB(_ value: Int) { setSetting("logging.max_size_mb", value: String(value)) }
    func setLoggingBackupCount(_ value: Int) { setSetting("logging.backup_count", value: String(value)) }
    func setDelegationModel(_ value: String) { setSetting("delegation.model", value: value) }
    func setDelegationProvider(_ value: String) { setSetting("delegation.provider", value: value) }
    func setDelegationBaseURL(_ value: String) { setSetting("delegation.base_url", value: value) }
    func setDelegationMaxIterations(_ value: Int) { setSetting("delegation.max_iterations", value: String(value)) }
    func setCronWrapResponse(_ value: Bool) { setSetting("cron.wrap_response", value: value ? "true" : "false") }

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
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["backup"], timeout: 300)
            let zipPath = Self.extractZipPath(from: result.output)
            await MainActor.run {
                self.backupInProgress = false
                if result.exitCode == 0 {
                    if let zipPath {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: zipPath)])
                        self.saveMessage = "Backup saved"
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

    func runRestore(from url: URL) {
        backupInProgress = true
        Task.detached { [fileService] in
            let result = fileService.runHermesCLI(args: ["import", url.path], timeout: 300)
            await MainActor.run {
                self.backupInProgress = false
                self.saveMessage = result.exitCode == 0 ? "Restore complete — restart Scarf" : "Restore failed"
                if result.exitCode == 0 {
                    self.load()
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

    func presentRestorePicker() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Hermes backup archive to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func openConfigInEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: HermesPaths.configYAML))
    }

    private func parsePersonalities() -> [String] {
        var names: [String] = []
        var inPersonalities = false
        for line in rawConfigYAML.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "personalities:" && line.hasPrefix("  ") {
                inPersonalities = true
                continue
            }
            if inPersonalities {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                let indent = line.prefix(while: { $0 == " " }).count
                if indent <= 2 && !trimmed.isEmpty {
                    inPersonalities = false
                    continue
                }
                if indent == 4 && trimmed.contains(":") {
                    let name = String(trimmed.split(separator: ":")[0])
                    names.append(name)
                }
            }
        }
        return names
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
        process.arguments = arguments
        process.environment = HermesFileService.enrichedEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        } catch {
            logger.error("Failed to run hermes \(arguments.joined(separator: " ")): \(error.localizedDescription)")
            return ("", -1)
        }
    }
}
