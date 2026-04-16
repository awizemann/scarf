import Foundation
import AppKit
import os

/// A personality defined under the `personalities:` block in config.yaml.
/// Each entry may have a free-form `prompt` string plus arbitrary extra fields.
struct HermesPersonality: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let prompt: String
}

@Observable
final class PersonalitiesViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "PersonalitiesViewModel")
    private let fileService = HermesFileService()

    var personalities: [HermesPersonality] = []
    var activeName: String = ""
    var soulMarkdown: String = ""
    var soulPath: String { HermesPaths.home + "/SOUL.md" }
    var message: String?

    func load() {
        let config = fileService.loadConfig()
        activeName = config.personality
        personalities = parsePersonalitiesBlock()
        soulMarkdown = (try? String(contentsOfFile: soulPath, encoding: .utf8)) ?? ""
    }

    /// Parse the `personalities:` section of config.yaml using the nested parser.
    /// Each personality is a top-level key under `personalities`, optionally with
    /// a `prompt:` child.
    private func parsePersonalitiesBlock() -> [HermesPersonality] {
        guard let yaml = try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8) else { return [] }
        let parsed = HermesFileService.parseNestedYAML(yaml)
        // Find all keys "personalities.<name>[.subkey]"
        var nameSet: Set<String> = []
        for key in parsed.values.keys where key.hasPrefix("personalities.") {
            let parts = key.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2 { nameSet.insert(String(parts[1])) }
        }
        for key in parsed.lists.keys where key.hasPrefix("personalities.") {
            let parts = key.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2 { nameSet.insert(String(parts[1])) }
        }
        return nameSet.sorted().map { name in
            let prompt = parsed.values["personalities.\(name).prompt"] ?? ""
            return HermesPersonality(name: name, prompt: HermesFileService.stripYAMLQuotes(prompt))
        }
    }

    func setActive(_ name: String) {
        let result = runHermes(["config", "set", "display.personality", name])
        if result.exitCode == 0 {
            activeName = name
            message = "Active personality set to \(name)"
        } else {
            logger.warning("Failed to set personality: \(result.output)")
            message = "Failed to set personality"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
        }
    }

    func saveSOUL(_ content: String) {
        do {
            try content.write(toFile: soulPath, atomically: true, encoding: .utf8)
            soulMarkdown = content
            message = "SOUL.md saved"
        } catch {
            logger.error("Failed to write SOUL.md: \(error.localizedDescription)")
            message = "Save failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
        }
    }

    func openConfigInEditor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: HermesPaths.configYAML))
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
            return ("", -1)
        }
    }
}
