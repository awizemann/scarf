import Foundation
import AppKit
import UniformTypeIdentifiers

@Observable
final class SettingsViewModel {
    private let fileService = HermesFileService()

    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var rawConfigYAML = ""
    var personalities: [String] = []
    var providers = ["anthropic", "openrouter", "nous", "openai-codex", "google-ai-studio", "xai", "ollama-cloud", "zai", "kimi-coding", "minimax"]
    var terminalBackends = ["local", "docker", "singularity", "modal", "daytona", "ssh"]
    var browserBackends = ["browseruse", "firecrawl", "local"]
    var saveMessage: String?
    var showAuthRemoveConfirmation = false

    func load() {
        config = fileService.loadConfig()
        gatewayState = fileService.loadGatewayState()
        hermesRunning = fileService.isHermesRunning()
        do {
            rawConfigYAML = try String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8)
        } catch {
            print("[Scarf] Failed to read config.yaml: \(error.localizedDescription)")
            rawConfigYAML = ""
        }
        personalities = parsePersonalities()
    }

    func setSetting(_ key: String, value: String) {
        let result = runHermes(["config", "set", key, value])
        if result.exitCode == 0 {
            saveMessage = "Saved \(key)"
            config = fileService.loadConfig()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveMessage = nil
            }
        }
    }

    func setModel(_ value: String) { setSetting("model.default", value: value) }
    func setProvider(_ value: String) { setSetting("model.provider", value: value) }
    func setPersonality(_ value: String) { setSetting("display.personality", value: value) }
    func setTerminalBackend(_ value: String) { setSetting("terminal.backend", value: value) }
    func setMaxTurns(_ value: Int) { setSetting("agent.max_turns", value: String(value)) }
    func setMemoryEnabled(_ value: Bool) { setSetting("memory.memory_enabled", value: value ? "true" : "false") }
    func setMemoryCharLimit(_ value: Int) { setSetting("memory.memory_char_limit", value: String(value)) }
    func setUserCharLimit(_ value: Int) { setSetting("memory.user_char_limit", value: String(value)) }
    func setNudgeInterval(_ value: Int) { setSetting("memory.nudge_interval", value: String(value)) }
    func setStreaming(_ value: Bool) { setSetting("display.streaming", value: value ? "true" : "false") }
    func setShowReasoning(_ value: Bool) { setSetting("display.show_reasoning", value: value ? "true" : "false") }
    func setVerbose(_ value: Bool) { setSetting("agent.verbose", value: value ? "true" : "false") }
    func setAutoTTS(_ value: Bool) { setSetting("voice.auto_tts", value: value ? "true" : "false") }
    func setSilenceThreshold(_ value: Int) { setSetting("voice.silence_threshold", value: String(value)) }
    func setReasoningEffort(_ value: String) { setSetting("agent.reasoning_effort", value: value) }
    func setShowCost(_ value: Bool) { setSetting("display.show_cost", value: value ? "true" : "false") }
    func setApprovalMode(_ value: String) { setSetting("approvals.mode", value: value) }
    func setBrowserBackend(_ value: String) { setSetting("browser.backend", value: value) }
    func setServiceTier(_ value: String) { setSetting("agent.service_tier", value: value) }
    func setGatewayNotifyInterval(_ value: Int) { setSetting("agent.gateway_notify_interval", value: String(value)) }
    func setForceIPv4(_ value: Bool) { setSetting("network.force_ipv4", value: value ? "true" : "false") }
    func setInterimAssistantMessages(_ value: Bool) { setSetting("display.interim_assistant_messages", value: value ? "true" : "false") }
    // Hermes v0.9.0 PR #6995: the key is camelCase in config.yaml (not snake_case like the rest of Hermes).
    func setHonchoInitOnSessionStart(_ value: Bool) { setSetting("honcho.initOnSessionStart", value: value ? "true" : "false") }

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

    func removeAuth() {
        let result = runHermes(["auth", "remove"])
        if result.exitCode == 0 {
            saveMessage = "Credentials removed"
        } else {
            saveMessage = "Failed to remove credentials"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveMessage = nil
        }
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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        } catch {
            return ("", -1)
        }
    }
}
