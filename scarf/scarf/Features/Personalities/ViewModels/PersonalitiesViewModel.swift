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
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    var personalities: [HermesPersonality] = []
    var activeName: String = ""
    var soulMarkdown: String = ""
    var soulPath: String { context.paths.soulMD }
    var message: String?

    func load() {
        let svc = fileService
        let ctx = context
        let path = soulPath
        Task.detached { [weak self] in
            let config = svc.loadConfig()
            let parsed = Self.parsePersonalitiesBlock(yaml: ctx.readText(ctx.paths.configYAML) ?? "")
            let soul = ctx.readText(path) ?? ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeName = config.personality
                self.personalities = parsed
                self.soulMarkdown = soul
            }
        }
    }

    /// Static form so the detached load can call into it without touching
    /// MainActor-isolated state. The instance form below remains for any
    /// other callers that need it.
    private static func parsePersonalitiesBlock(yaml: String) -> [HermesPersonality] {
        guard !yaml.isEmpty else { return [] }
        let parsed = HermesFileService.parseNestedYAML(yaml)
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

    /// Parse the `personalities:` section of config.yaml using the nested parser.
    /// Each personality is a top-level key under `personalities`, optionally with
    /// a `prompt:` child.
    private func parsePersonalitiesBlock() -> [HermesPersonality] {
        guard let yaml = context.readText(context.paths.configYAML) else { return [] }
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
        if context.writeText(soulPath, content: content) {
            soulMarkdown = content
            message = "SOUL.md saved"
        } else {
            logger.error("Failed to write SOUL.md to \(self.context.displayName)")
            message = "Save failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
        }
    }

    func openConfigInEditor() {
        context.openInLocalEditor(context.paths.configYAML)
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}
