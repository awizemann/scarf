import Foundation
import AppKit

@Observable
final class SettingsViewModel {
    private let fileService = HermesFileService()

    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var rawConfigYAML = ""
    var personalities: [String] = []
    var providers = ["anthropic", "openrouter", "nous", "openai-codex", "zai", "kimi-coding", "minimax"]
    var terminalBackends = ["local", "docker", "singularity", "modal", "daytona", "ssh"]
    var saveMessage: String?

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
