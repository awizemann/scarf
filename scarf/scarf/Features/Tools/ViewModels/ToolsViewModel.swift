import Foundation
import os

/// Connection/configuration status for a messaging platform, used for indicator dots in the picker.
enum PlatformConnectivity: Sendable, Equatable {
    case connected              // Gateway reports the platform online
    case configured             // Platform has a config block but gateway isn't reporting it as connected
    case notConfigured          // No signal that this platform has been set up
    case error(String)          // Gateway reports an error for this platform
}

@Observable
final class ToolsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ToolsViewModel")

    var selectedPlatform: HermesToolPlatform = KnownPlatforms.cli
    var toolsets: [HermesToolset] = []
    var mcpStatus: String = ""
    var isLoading = false
    var availablePlatforms: [HermesToolPlatform] = []
    var connectivity: [String: PlatformConnectivity] = [:]

    @MainActor
    func load() async {
        isLoading = true
        await loadPlatforms()
        await loadTools(for: selectedPlatform)
        await loadMCPStatus()
        isLoading = false
    }

    @MainActor
    func switchPlatform(_ platform: HermesToolPlatform) async {
        selectedPlatform = platform
        await loadTools(for: platform)
    }

    @MainActor
    func toggleTool(_ tool: HermesToolset) async {
        guard let idx = toolsets.firstIndex(where: { $0.name == tool.name }) else { return }
        toolsets[idx].enabled.toggle()
        let newEnabled = toolsets[idx].enabled

        let action = newEnabled ? "enable" : "disable"
        let result = await runHermes(["tools", action, tool.name, "--platform", selectedPlatform.name])

        if result.exitCode != 0 {
            if let idx = toolsets.firstIndex(where: { $0.name == tool.name }) {
                toolsets[idx].enabled = !newEnabled
            }
        }
    }

    /// Enumerate all known platforms and compute a connectivity status per platform.
    ///
    /// Source of truth:
    /// - `KnownPlatforms.all` defines every platform the app knows about (always show these).
    /// - `~/.hermes/gateway_state.json` tells us which are currently connected.
    /// - `~/.hermes/config.yaml` top-level keys (`discord:`, `whatsapp:`, etc.) tell us which have been configured.
    @MainActor
    private func loadPlatforms() async {
        let yaml: String = await Task.detached {
            (try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8)) ?? ""
        }.value

        let gatewayState: GatewayState? = await Task.detached {
            HermesFileService().loadGatewayState()
        }.value

        let configuredNames = Self.parseConfiguredPlatforms(yaml: yaml)
        var status: [String: PlatformConnectivity] = [:]

        for platform in KnownPlatforms.all {
            if let pState = gatewayState?.platforms?[platform.name] {
                if let err = pState.error, !err.isEmpty {
                    status[platform.name] = .error(err)
                } else if pState.connected == true {
                    status[platform.name] = .connected
                } else if configuredNames.contains(platform.name) || platform.name == "cli" {
                    status[platform.name] = .configured
                } else {
                    status[platform.name] = .notConfigured
                }
            } else if configuredNames.contains(platform.name) || platform.name == "cli" {
                status[platform.name] = .configured
            } else {
                status[platform.name] = .notConfigured
            }
        }

        connectivity = status
        availablePlatforms = KnownPlatforms.all
        if !availablePlatforms.contains(where: { $0.name == selectedPlatform.name }),
           let first = availablePlatforms.first {
            selectedPlatform = first
        }
    }

    /// Find top-level YAML keys that look like messaging platform sections.
    /// Matches any known platform name followed by `:` at indent 0.
    private static func parseConfiguredPlatforms(yaml: String) -> Set<String> {
        var found: Set<String> = []
        let knownNames = Set(KnownPlatforms.all.map(\.name))
        for line in yaml.components(separatedBy: "\n") {
            guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(":") else { continue }
            let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            if knownNames.contains(name) {
                found.insert(name)
            }
        }
        return found
    }

    @MainActor
    private func loadTools(for platform: HermesToolPlatform) async {
        let result = await runHermes(["tools", "list", "--platform", platform.name])
        toolsets = parseToolsList(result.output)
    }

    @MainActor
    private func loadMCPStatus() async {
        let result = await runHermes(["mcp", "list"])
        mcpStatus = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseToolsList(_ output: String) -> [HermesToolset] {
        var tools: [HermesToolset] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isEnabled: Bool
            if trimmed.hasPrefix("✓ enabled") {
                isEnabled = true
            } else if trimmed.hasPrefix("✗ disabled") {
                isEnabled = false
            } else {
                continue
            }
            let rest = trimmed
                .replacingOccurrences(of: "✓ enabled", with: "")
                .replacingOccurrences(of: "✗ disabled", with: "")
                .trimmingCharacters(in: .whitespaces)

            let parts = rest.split(separator: " ", maxSplits: 1)
            guard let namePart = parts.first else { continue }
            let name = String(namePart)
            let rawDesc = parts.count > 1 ? String(parts[1]) : name

            let icon = extractEmoji(from: rawDesc)
            let description = rawDesc
                .unicodeScalars.filter { !$0.properties.isEmoji || $0.isASCII }
                .map { String($0) }.joined()
                .trimmingCharacters(in: .whitespaces)

            tools.append(HermesToolset(name: name, description: description, icon: icon, enabled: isEnabled))
        }
        return tools
    }

    private func extractEmoji(from text: String) -> String {
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmoji && !scalar.isASCII {
                return String(scalar)
            }
        }
        return "🔧"
    }

    private nonisolated func runHermes(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                return (output, process.terminationStatus)
            } catch {
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                return ("", -1)
            }
        }.value
    }
}
