import Foundation
import os

@Observable
final class ToolsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ToolsViewModel")

    var selectedPlatform: HermesToolPlatform = KnownPlatforms.cli
    var toolsets: [HermesToolset] = []
    var mcpStatus: String = ""
    var isLoading = false
    var availablePlatforms: [HermesToolPlatform] = []

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

    @MainActor
    private func loadPlatforms() async {
        let config: String
        do {
            config = try await Task.detached {
                try String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8)
            }.value
        } catch {
            logger.error("Failed to read config.yaml: \(error.localizedDescription)")
            config = ""
        }
        var platforms: [HermesToolPlatform] = []
        var inSection = false
        for line in config.components(separatedBy: "\n") {
            if line.hasPrefix("platform_toolsets:") {
                inSection = true
                continue
            }
            if inSection {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || (!line.hasPrefix(" ") && !line.hasPrefix("\t")) {
                    if !trimmed.isEmpty { break }
                    continue
                }
                if trimmed.hasSuffix(":") && !trimmed.hasPrefix("-") {
                    let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                    if let known = KnownPlatforms.all.first(where: { $0.name == name }) {
                        platforms.append(known)
                    } else {
                        platforms.append(HermesToolPlatform(name: name, displayName: name.capitalized, icon: "bubble.left"))
                    }
                }
            }
        }
        availablePlatforms = platforms.isEmpty ? [KnownPlatforms.cli] : platforms
        if !availablePlatforms.contains(where: { $0.name == selectedPlatform.name }),
           let first = availablePlatforms.first {
            selectedPlatform = first
        }
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
