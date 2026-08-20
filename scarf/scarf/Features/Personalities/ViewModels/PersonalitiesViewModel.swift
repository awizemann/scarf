import Foundation
import ScarfCore
import AppKit
import os

/// A personality available to the agent: a Hermes built-in, or a user entry
/// under the `agent.personalities:` block in config.yaml.
struct HermesPersonality: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let prompt: String
    let isBuiltin: Bool

    nonisolated init(name: String, prompt: String, isBuiltin: Bool = false) {
        self.name = name
        self.prompt = prompt
        self.isBuiltin = isBuiltin
    }

    nonisolated init(_ entry: HermesPersonalityEntry) {
        self.init(name: entry.name, prompt: entry.prompt, isBuiltin: entry.isBuiltin)
    }
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

    /// Host capability, pushed in by `PersonalitiesView` from
    /// `\.hermesCapabilities` before `load()`. Decides whether the 14 in-code
    /// built-ins are unioned into the list — see `HermesPersonalities.resolve`.
    /// Defaults to `false` (the conservative pre-v0.20.4 reading: show only
    /// what the config actually contains) until capabilities are known.
    var hasBuiltinPersonalitiesInCode: Bool = false

    var personalities: [HermesPersonality] = []
    var activeName: String = ""
    var soulMarkdown: String = ""
    var soulPath: String { context.paths.soulMD }
    var message: String?

    /// Picker rows for the active selection: neutral `default`, the resolved
    /// names, plus the current selection if it matches none of them.
    var activeOptions: [String] {
        var options = ["default"] + personalities.map(\.name)
        let current = activeName.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty, !options.contains(current) { options.insert(current, at: 1) }
        return options
    }

    func load() {
        let svc = fileService
        let ctx = context
        let path = soulPath
        let inCodeBuiltins = hasBuiltinPersonalitiesInCode
        Task.detached { [weak self] in
            let config = svc.loadConfig()
            let parsed = Self.parsePersonalitiesBlock(
                yaml: ctx.readText(ctx.paths.configYAML) ?? "",
                hasBuiltinPersonalitiesInCode: inCodeBuiltins
            )
            let soul = ctx.readText(path) ?? ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeName = config.personality
                self.personalities = parsed
                self.soulMarkdown = soul
            }
        }
    }

    /// The user entries under `agent.personalities`, unioned with Hermes'
    /// in-code `BUILTIN_PERSONALITIES` only on hosts that actually have them
    /// in code — see `HermesPersonalities.resolve` for why a pre-v0.20.4
    /// host must not have deleted built-ins resurrected.
    ///
    /// Static form so the detached load can call into it without touching
    /// MainActor-isolated state.
    nonisolated private static func parsePersonalitiesBlock(
        yaml: String,
        hasBuiltinPersonalitiesInCode: Bool
    ) -> [HermesPersonality] {
        HermesPersonalities
            .resolve(yaml: yaml, hasBuiltinPersonalitiesInCode: hasBuiltinPersonalitiesInCode)
            .map(HermesPersonality.init)
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
