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
        let ctx = context
        let path = soulPath
        let inCodeBuiltins = hasBuiltinPersonalitiesInCode
        Task.detached { [weak self] in
            // ONE read of config.yaml, not two. `loadConfig()` reads and
            // parses the file, and the personalities block was then re-read
            // from disk a second time through `ctx.readText` — two SFTP
            // round-trips over the identical bytes on every Personalities
            // visit. Read the text once and derive both from it.
            let yaml = ctx.readText(ctx.paths.configYAML) ?? ""
            let config = HermesConfig(yaml: yaml)
            let parsed = Self.parsePersonalitiesBlock(
                yaml: yaml,
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

    /// True while a `hermes config set` or a SOUL.md write is in flight.
    /// The picker and the Save button disable on it, so the transition
    /// actually renders instead of the window freezing for the round-trip.
    private(set) var isSaving = false

    func setActive(_ name: String) {
        guard !isSaving else { return }
        isSaving = true
        let ctx = context
        Task { [weak self] in
            // `hermes config set` is a process spawn — an SSH exec channel on
            // a remote host. Detached, matching `load()` right above.
            let result = await Task.detached {
                ctx.runHermes(["config", "set", "display.personality", name])
            }.value
            guard let self else { return }
            self.isSaving = false
            if result.exitCode == 0 {
                self.activeName = name
                self.message = "Active personality set to \(name)"
            } else {
                self.logger.warning("Failed to set personality: \(result.output)")
                // Same `hermes config set` failure surface as Settings, so use
                // the shared builder: it quotes the CLI's own reason (e.g. the
                // managed-scope refusal) instead of a generic string.
                self.message = SettingsViewModel.saveFailureMessage(
                    key: "display.personality", output: result.output
                )
            }
            self.clearMessageAfterDelay()
        }
    }

    func saveSOUL(_ content: String) {
        guard !isSaving else { return }
        isSaving = true
        let ctx = context
        let path = soulPath
        Task { [weak self] in
            let ok = await Task.detached { ctx.writeText(path, content: content) }.value
            guard let self else { return }
            self.isSaving = false
            if ok {
                self.soulMarkdown = content
                self.message = "SOUL.md saved"
            } else {
                self.logger.error("Failed to write SOUL.md to \(self.context.displayName)")
                self.message = "Save failed"
            }
            self.clearMessageAfterDelay()
        }
    }

    private func clearMessageAfterDelay() {
        messageClearTask?.cancel()
        messageClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    /// Held so a second action's message isn't wiped by the first action's
    /// still-pending timer.
    @ObservationIgnored private var messageClearTask: Task<Void, Never>?

    func openConfigInEditor() {
        context.openInLocalEditor(context.paths.configYAML)
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}
