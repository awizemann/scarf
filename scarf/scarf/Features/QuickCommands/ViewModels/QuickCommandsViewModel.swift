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
final class QuickCommandsViewModel: OutcomeMessageHosting {
    private let logger = Logger(subsystem: "com.scarf", category: "QuickCommandsViewModel")
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    var commands: [HermesQuickCommand] = []
    var message: String?
    /// Outcome of `message` (GW-F4) — the bar's colour, glyph and VoiceOver
    /// announcement come from this stored fact, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false

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
            showSaveFailure(String(localized: "Name and command are required"))
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
            let (typeResult, cmdResult) = await OffPool.run {
                (
                    ctx.runHermes(HermesConfigSet.argv(
                        key: "quick_commands.\(sanitizedName).type", value: "exec")),
                    ctx.runHermes(HermesConfigSet.argv(
                        key: "quick_commands.\(sanitizedName).command", value: command))
                )
            }
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

    /// Internal, not private, so a test can drive the two results directly —
    /// the same seam `SettingsViewModel.saveFailureMessage` uses. Which of the
    /// two writes failed is a verdict question (P39), and getting it wrong
    /// names the wrong key in the banner.
    func applyAddOrUpdateResult(
        sanitizedName: String,
        typeResult: (output: String, exitCode: Int32),
        cmdResult: (output: String, exitCode: Int32)
    ) {
        // P39: output-judged. `set_config_value`'s managed-install arm exits
        // 0 (`hermes_cli/config.py:3450-3452` @ v2026.9.7), so both spawns
        // "succeeded" and the sheet toasted a command that was never saved.
        let typeOK = HermesConfigSet.judge(output: typeResult.output, exitCode: typeResult.exitCode).succeeded
        let cmdOK = HermesConfigSet.judge(output: cmdResult.output, exitCode: cmdResult.exitCode).succeeded
        if typeOK && cmdOK {
            // Toast carries the name the command was actually SAVED under,
            // never the raw CLI segment. `ConfigDottedKeySegment.escaped`
            // backslash-escapes dots on v0.21+ hosts, so "v1.2 deploy" used
            // to toast "Saved /v1\.2_deploy" — a name that exists nowhere:
            // the backslash is CLI-path syntax, not part of the key, and the
            // list below renders "v1.2_deploy". Unescaping puts the toast
            // back in agreement with the list on both host generations (on
            // pre-0.21 hosts the dot is stripped rather than escaped, and
            // the stripped form IS the saved name, so it stands).
            let saved = sanitizedName.replacingOccurrences(of: "\\.", with: ".")
            showSuccess(String(localized: "Saved /\(saved)"))
            load(force: true)
        } else {
            logger.warning("Failed to save quick command: type=\(typeResult.output) cmd=\(cmdResult.output)")
            // Surface the CLI's own reason, the way Settings and
            // Personalities do — "Save failed" alone hid the managed-scope
            // refusal that is the common cause here.
            //
            // P39: which one failed is decided by the VERDICT, not by the
            // exit code. An exit-0 refusal on the `type` write used to read
            // as "type is fine", so the banner quoted the `command` key and
            // the `command` output — naming the wrong key for the wrong
            // reason.
            let failing = !typeOK ? typeResult : cmdResult
            let key = !typeOK
                ? "quick_commands.\(sanitizedName).type"
                : "quick_commands.\(sanitizedName).command"
            // GW-F4: a refusal stays on the bar in the failure style until
            // the user dismisses it. It used to render under a green
            // checkmark and vanish after two seconds.
            showSaveFailure(SettingsViewModel.saveFailureMessage(
                key: key,
                output: failing.output,
                reason: HermesConfigSet.judge(
                    output: failing.output, exitCode: failing.exitCode).detail
            ))
        }
    }

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
