import Foundation
import ScarfCore
import os

/// Drives the per-project Slash Commands tab on Mac. Loads commands from
/// `<project>/.scarf/slash-commands/` via `ProjectSlashCommandService`,
/// supports save / delete / duplicate, and surfaces an inline error
/// banner on failures (rather than silent log).
///
/// Pure UI shell — the actual on-disk shape + parser + frontmatter
/// validation lives in ScarfCore's `ProjectSlashCommandService`. This
/// view-model just owns the editor's draft state + dirty tracking.
@MainActor
@Observable
final class ProjectSlashCommandsViewModel {
    private static let logger = Logger(
        subsystem: "com.scarf",
        category: "ProjectSlashCommandsViewModel"
    )

    let project: ProjectEntry
    private let service: ProjectSlashCommandService

    // MARK: - List state

    private(set) var commands: [ProjectSlashCommand] = []
    private(set) var isLoading: Bool = true
    var lastError: String?

    // MARK: - Editor state

    /// Non-nil when the editor sheet is open. The view binds to this
    /// to drive `.sheet(item:)`. Created via `beginNew()` or
    /// `beginEdit(_:)`; cleared on close (cancel) or save.
    var draft: Draft?

    init(project: ProjectEntry, context: ServerContext = .local) {
        self.project = project
        self.service = ProjectSlashCommandService(context: context)
    }

    // MARK: - List actions

    func load() async {
        isLoading = true
        let svc = service
        let proj = project.path
        commands = await Task.detached {
            svc.loadCommands(at: proj)
        }.value
        isLoading = false
    }

    /// Open the editor sheet for a brand-new command. Pre-fills sensible
    /// defaults so the form is immediately usable.
    func beginNew() {
        draft = Draft(
            isNew: true,
            originalName: nil,
            name: "",
            description: "",
            argumentHint: "",
            model: "",
            tags: "",
            body: "Describe what the agent should do.\n\nUser argument: {{argument | default: \"none\"}}.\n"
        )
    }

    /// Open the editor sheet pre-populated with an existing command's
    /// fields. The original name is captured so a rename can clean up
    /// the previous file on save.
    func beginEdit(_ command: ProjectSlashCommand) {
        draft = Draft(
            isNew: false,
            originalName: command.name,
            name: command.name,
            description: command.description,
            argumentHint: command.argumentHint ?? "",
            model: command.model ?? "",
            tags: (command.tags ?? []).joined(separator: ", "),
            body: command.body
        )
    }

    /// Open the editor for a fresh copy of an existing command. The name
    /// is suffixed with `-copy` so the user has a starting point that
    /// won't collide.
    func beginDuplicate(of command: ProjectSlashCommand) {
        draft = Draft(
            isNew: true,
            originalName: nil,
            name: "\(command.name)-copy",
            description: command.description,
            argumentHint: command.argumentHint ?? "",
            model: command.model ?? "",
            tags: (command.tags ?? []).joined(separator: ", "),
            body: command.body
        )
    }

    func cancelEdit() {
        draft = nil
    }

    /// Validate the draft, persist via the service, and reload the list.
    /// Returns true on success so the sheet can dismiss; populates
    /// `lastError` on failure (the sheet stays open so the user can fix).
    @discardableResult
    func saveDraft() async -> Bool {
        guard let d = draft else { return false }
        if let reason = ProjectSlashCommand.validateName(d.name) {
            lastError = reason
            return false
        }
        // On rename, prevent overwriting an unrelated existing command.
        if let originalName = d.originalName, originalName != d.name,
           commands.contains(where: { $0.name == d.name }) {
            lastError = "A command named \"\(d.name)\" already exists. Pick a different name or delete the old one first."
            return false
        }
        if d.isNew, commands.contains(where: { $0.name == d.name }) {
            lastError = "A command named \"\(d.name)\" already exists in this project."
            return false
        }
        let cmd = ProjectSlashCommand(
            name: d.name,
            description: d.description.trimmingCharacters(in: .whitespacesAndNewlines),
            argumentHint: d.argumentHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : d.argumentHint,
            model: d.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : d.model,
            tags: parseTags(d.tags),
            body: d.body,
            sourcePath: ""  // service ignores this on save
        )
        let svc = service
        let proj = project.path
        let originalName = d.originalName
        let result: Result<Void, Error> = await Task.detached {
            do {
                try svc.save(cmd, at: proj)
                if let originalName, originalName != cmd.name {
                    try svc.delete(named: originalName, at: proj)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            lastError = nil
            draft = nil
            await load()
            return true
        case .failure(let error):
            Self.logger.error("save failed for \(cmd.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ command: ProjectSlashCommand) async {
        let svc = service
        let proj = project.path
        let name = command.name
        let result: Result<Void, Error> = await Task.detached {
            do {
                try svc.delete(named: name, at: proj)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = result {
            Self.logger.error("delete failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't delete \"\(name)\": \(error.localizedDescription)"
            return
        }
        lastError = nil
        await load()
    }

    /// Render a preview of the draft body with `{{argument}}` substituted
    /// against a user-supplied sample argument. Used by the editor's
    /// preview pane.
    func previewExpansion(forArgument argument: String) -> String {
        guard let d = draft else { return "" }
        let cmd = ProjectSlashCommand(
            name: d.name.isEmpty ? "preview" : d.name,
            description: d.description,
            body: d.body,
            sourcePath: ""
        )
        return service.expand(cmd, withArgument: argument)
    }

    // MARK: - Draft model

    /// Editor draft state. Pure value — bound to TextField inputs so
    /// changes flow through SwiftUI state. `Identifiable` via name so
    /// `.sheet(item:)` can present it.
    struct Draft: Identifiable {
        var id: String { isNew ? "draft-new" : (originalName ?? "draft-edit") }
        let isNew: Bool
        /// Filename before the user typed in the editor (used to
        /// detect renames). Nil on `.beginNew`.
        let originalName: String?
        var name: String
        var description: String
        var argumentHint: String
        var model: String
        /// Comma-separated user-typed tag list. Parsed on save.
        var tags: String
        var body: String
    }

    // MARK: - Helpers

    private func parseTags(_ raw: String) -> [String]? {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleaned = parts.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }
}
