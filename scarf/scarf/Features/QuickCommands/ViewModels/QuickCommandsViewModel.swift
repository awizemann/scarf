import Foundation
import ScarfCore
import AppKit
import os

/// A user-defined shell shortcut that hermes exposes in chat (e.g. `/my_cmd`).
struct HermesQuickCommand: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let type: String     // "exec" is the only supported type today
    let command: String
}

@Observable
final class QuickCommandsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "QuickCommandsViewModel")
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    var commands: [HermesQuickCommand] = []
    var message: String?

    /// `hasLoaded` lets a plain section re-entry skip the re-read (the VM is
    /// cached in `AppCoordinator` and persists across switches); Reload and
    /// post-save reloads pass `force: true` (t-aud24).
    @ObservationIgnored private var hasLoaded = false

    func load(force: Bool = false) {
        if !force, hasLoaded { return }
        hasLoaded = true
        let ctx = context
        Task.detached { [weak self] in
            let result = Self.loadQuickCommands(context: ctx)
            await MainActor.run { [weak self] in self?.commands = result }
        }
    }

    /// Parse `quick_commands` from `config.yaml` on the given context. Safe to
    /// call from any actor — performs synchronous file I/O, so dispatch from a
    /// detached task when called from `@MainActor`.
    nonisolated static func loadQuickCommands(context: ServerContext) -> [HermesQuickCommand] {
        guard let yaml = context.readText(context.paths.configYAML) else { return [] }
        // Shared with the iOS slash-menu reader (RichChatViewModel) via
        // `HermesQuickCommandsYAML` — one place owns the dotted-name
        // suffix-peel ("v1.2_deploy") and the folded-scalar handling.
        return HermesQuickCommandsYAML.entries(inYAML: yaml)
            .map { HermesQuickCommand(name: $0.name, type: $0.type, command: $0.command) }
    }

    /// Check for obviously destructive shell strings. Display-only; we do not block.
    static func isDangerous(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let patterns = ["rm -rf /", "rm -rf ~", ":(){", "mkfs", "dd if=", "> /dev/sd", "shutdown", "reboot"]
        return patterns.contains { lowered.contains($0) }
    }

    func addOrUpdate(name: String, command: String) {
        guard !name.isEmpty, !command.isEmpty else {
            message = "Name and command are required"
            return
        }
        // A literal "." in the name (e.g. "v1.2 deploy") would otherwise be
        // parsed by `hermes config set` as a nesting separator and corrupt
        // config.yaml — escape it (v0.21+) or strip it (older hosts) via
        // the shared helper so the write is always safe. Display name keeps
        // the raw dot; only the interpolated CLI segment is transformed.
        let caps = HermesVersionCache.shared.cached(for: context) ?? .empty
        let sanitizedName = ConfigDottedKeySegment.escaped(name, capabilities: caps)
        isSaving = true
        let ctx = context
        Task { [weak self] in
            // TWO `hermes config set` process spawns — two SSH exec channels
            // on a remote host — were running inline on the MainActor.
            // Detached, matching `load()` above. They stay SEQUENTIAL inside
            // the detached body: both write config.yaml, and Hermes's writer
            // is read-modify-write, so overlapping them would lose one key.
            let (typeResult, cmdResult) = await Task.detached {
                (
                    ctx.runHermes(["config", "set", "quick_commands.\(sanitizedName).type", "exec"]),
                    ctx.runHermes(["config", "set", "quick_commands.\(sanitizedName).command", command])
                )
            }.value
            guard let self else { return }
            self.isSaving = false
            self.applyAddOrUpdateResult(
                sanitizedName: sanitizedName, typeResult: typeResult, cmdResult: cmdResult
            )
        }
    }

    /// True while `addOrUpdate` is writing. The sheet's Save button disables
    /// on it so the busy state renders.
    private(set) var isSaving = false

    private func applyAddOrUpdateResult(
        sanitizedName: String,
        typeResult: (output: String, exitCode: Int32),
        cmdResult: (output: String, exitCode: Int32)
    ) {
        if typeResult.exitCode == 0 && cmdResult.exitCode == 0 {
            // Toast carries the name the command was actually SAVED under,
            // never the raw CLI segment. `ConfigDottedKeySegment.escaped`
            // backslash-escapes dots on v0.21+ hosts, so "v1.2 deploy" used
            // to toast "Saved /v1\.2_deploy" — a name that exists nowhere:
            // the backslash is CLI-path syntax, not part of the key, and the
            // list below renders "v1.2_deploy". Unescaping puts the toast
            // back in agreement with the list on both host generations (on
            // pre-0.21 hosts the dot is stripped rather than escaped, and
            // the stripped form IS the saved name, so it stands).
            message = "Saved /\(sanitizedName.replacingOccurrences(of: "\\.", with: "."))"
            load(force: true)
        } else {
            logger.warning("Failed to save quick command: type=\(typeResult.output) cmd=\(cmdResult.output)")
            // Surface the CLI's own reason, the way Settings and
            // Personalities do — "Save failed" alone hid the managed-scope
            // refusal that is the common cause here.
            let failing = typeResult.exitCode != 0 ? typeResult : cmdResult
            let key = typeResult.exitCode != 0
                ? "quick_commands.\(sanitizedName).type"
                : "quick_commands.\(sanitizedName).command"
            message = SettingsViewModel.saveFailureMessage(key: key, output: failing.output)
        }
        messageClearTask?.cancel()
        messageClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    @ObservationIgnored private var messageClearTask: Task<Void, Never>?

    /// Removal requires editing config.yaml directly — `hermes config set` has no
    /// unset for nested keys. Open the file in the editor for manual removal.
    func openConfigForRemoval() {
        context.openInLocalEditor(context.paths.configYAML)
    }

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}
