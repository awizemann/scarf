import Foundation
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

    func load() {
        let ctx = context
        Task.detached { [weak self] in
            let yaml = ctx.readText(ctx.paths.configYAML)
            let result: [HermesQuickCommand] = {
                guard let yaml else { return [] }
                let parsed = HermesFileService.parseNestedYAML(yaml)
                var byName: [String: (type: String, command: String)] = [:]
                for (key, value) in parsed.values where key.hasPrefix("quick_commands.") {
                    let parts = key.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3 else { continue }
                    let name = String(parts[1])
                    let field = String(parts[2])
                    var existing = byName[name] ?? (type: "exec", command: "")
                    let stripped = HermesFileService.stripYAMLQuotes(value)
                    if field == "type" { existing.type = stripped }
                    if field == "command" { existing.command = stripped }
                    byName[name] = existing
                }
                return byName.map { HermesQuickCommand(name: $0.key, type: $0.value.type, command: $0.value.command) }
                    .sorted { $0.name < $1.name }
            }()
            await MainActor.run { [weak self] in self?.commands = result }
        }
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
        let sanitizedName = name.replacingOccurrences(of: " ", with: "_")
        let typeResult = runHermes(["config", "set", "quick_commands.\(sanitizedName).type", "exec"])
        let cmdResult = runHermes(["config", "set", "quick_commands.\(sanitizedName).command", command])
        if typeResult.exitCode == 0 && cmdResult.exitCode == 0 {
            message = "Saved /\(sanitizedName)"
            load()
        } else {
            logger.warning("Failed to save quick command: type=\(typeResult.output) cmd=\(cmdResult.output)")
            message = "Save failed"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.message = nil
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
