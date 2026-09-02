import Foundation
import os
import Observation
import ScarfCore

/// State + commit logic for the "New Project from Scratch" wizard.
/// Drives `NewProjectSheet`. Hosts the form fields, derives a default
/// slug from the project name, validates inputs, and runs the
/// `ProjectScaffolder` on commit.
///
/// Pattern matches `TemplateConfigViewModel`: a tightly-scoped view
/// model that owns its sheet's state, exposes typed bindings, and
/// surfaces a single error string the sheet renders inline.
@Observable
@MainActor
final class NewProjectViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "NewProjectViewModel")
    private let context: ServerContext

    // MARK: - Form fields

    var projectName: String = "" {
        didSet {
            // Auto-derive slug from name as long as the user hasn't
            // edited the slug field manually. Once they edit it, we
            // stop tracking — the user's choice wins.
            if !slugManuallyEdited {
                folderName = ProjectScaffolder.suggestedSlug(from: projectName)
            }
        }
    }

    var folderName: String = "" {
        didSet {
            // Mark manually edited only if the change isn't from our
            // own auto-derivation. The didSet on projectName sets
            // folderName too — we differentiate by checking whether
            // the new value matches what suggestedSlug would produce.
            if folderName != ProjectScaffolder.suggestedSlug(from: projectName) {
                slugManuallyEdited = true
            }
        }
    }

    var parentDirectory: String = ""

    var description: String = ""

    /// User-facing error from the most recent commit attempt. Cleared
    /// when the user edits any field. Sheet renders this as an inline
    /// banner above the footer.
    var errorMessage: String?

    // MARK: - Internal state

    /// Tracks whether the user has typed in the folder-name field.
    /// Once true, we stop overriding their value when they edit the
    /// project name.
    private var slugManuallyEdited: Bool = false

    /// True while a commit is in flight. Disables the Create button
    /// to prevent double-taps.
    private(set) var isCommitting: Bool = false

    init(context: ServerContext) {
        self.context = context
        self.parentDirectory = Self.defaultParentDirectory()
    }

    // MARK: - Validation

    var canCommit: Bool {
        guard !isCommitting else { return false }
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard ProjectScaffolder.isValidSlug(folderName) else { return false }
        guard !parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    /// Resolved absolute path the project will land at — shown as a
    /// preview line above the footer so the user sees exactly what
    /// gets created.
    var resolvedProjectPath: String {
        let parent = ProjectScaffolder.normalizeDirectoryPath(parentDirectory)
        return parent + "/" + folderName
    }

    // MARK: - Commit

    /// Attempt to scaffold the project. Returns the registered
    /// `ProjectEntry` on success, nil on validation/scaffolder
    /// failure (with `errorMessage` populated for the sheet).
    /// Scaffold the project. `async` because the body is filesystem work
    /// through the context's transport — directory creation, several file
    /// writes, and a skill-bundle copy — which on a remote context is a
    /// string of SFTP round-trips. Run inline on the MainActor it froze the
    /// wizard for the whole scaffold, and `isCommitting` was set and
    /// `defer`-cleared inside that same synchronous run, so the spinner the
    /// sheet already draws for it could never appear.
    func commit() async -> ProjectEntry? {
        guard canCommit else {
            errorMessage = "Fill in the name, folder, and parent directory."
            return nil
        }
        guard !isCommitting else { return nil }
        isCommitting = true
        errorMessage = nil

        let ctx = context
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = folderName
        let parent = parentDirectory
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        let result: Result<ProjectEntry, Error> = await Task.detached { [logger] in
            Self.scaffoldOffMain(
                context: ctx, name: name, slug: slug, parentDir: parent,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                logger: logger
            )
        }.value

        isCommitting = false
        switch result {
        case .success(let entry):
            logger.info("scaffolded \(entry.name, privacy: .public) at \(entry.path, privacy: .public)")
            return entry
        case .failure(let error):
            errorMessage = error.localizedDescription
            logger.warning("scaffold failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func scaffoldOffMain(
        context: ServerContext,
        name: String,
        slug: String,
        parentDir: String,
        description: String?,
        logger: Logger
    ) -> Result<ProjectEntry, Error> {
        let scaffolder = ProjectScaffolder(context: context)
        do {
            let entry = try scaffolder.scaffold(
                name: name,
                slug: slug,
                parentDir: parentDir,
                description: description
            )
            // P3 of the projects-feature fix: bootstrap the bundled
            // `scarf-template-author` skill IMMEDIATELY before the
            // wizard hands off to chat. The launch-time bootstrap is a
            // detached task that may not have completed (cold launch,
            // remote context with a slow transport) or may have failed
            // silently. Running it here makes the wizard self-contained
            // — if the skill is already installed and current, this is
            // a no-op; otherwise it copies the bundled copy to
            // `~/.hermes/skills/scarf-template-author/` so Hermes loads
            // it on `session/new`. Non-fatal: a failed bootstrap just
            // means the agent might not recognize the skill, which the
            // user can recover from by typing `/reload-skills` once
            // they've installed it manually.
            do {
                try SkillBootstrapService(context: context).ensureBundledSkillsInstalled()
            } catch {
                logger.warning(
                    "skill preflight failed for new-project wizard: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .success(entry)
        } catch {
            return .failure(error)
        }
    }

    /// Build the auto-prompt the wizard hands to ChatViewModel after
    /// scaffolding.
    ///
    /// P3 of the projects-feature fix: the old prompt was a polite
    /// single-sentence request that the agent often ignored — it would
    /// reply conversationally without invoking the skill. The new
    /// prompt is structured so the agent treats the
    /// `scarf-template-author` skill as the literal next action:
    ///
    /// - States the skill name in `SKILL:` format twice (top + closing
    ///   reinforcement) — agents trained on tool-use patterns recognize
    ///   this as an invocation marker, not a suggestion.
    /// - Pins the cwd in `PROJECT_PATH:` so the agent can't drift to a
    ///   different folder if AGENTS.md hasn't been re-read yet.
    /// - Lists the skill's expected stages explicitly so the agent
    ///   doesn't have to discover them from the SKILL.md body.
    /// - Calls the user's description out as the FIRST QUESTION's
    ///   answer so the agent skips question 1 and jumps to question 2,
    ///   reducing the perceived "is anything happening?" delay.
    func buildInitialPrompt(for entry: ProjectEntry) -> String {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = """
        SKILL: scarf-template-author
        PROJECT_PATH: \(entry.path)
        PROJECT_NAME: \(entry.name)

        Run the `scarf-template-author` skill interview now. This is a freshly-scaffolded Scarf project with an empty dashboard and a managed AGENTS.md block. Walk me through:

        1. Purpose + data source — what does this project do and where does its data come from?
        2. Dashboard widgets — pick from the supported widget vocabulary documented in the skill.
        3. Configuration schema — only if the project takes user-supplied inputs (URLs, API tokens, etc.).
        4. Scheduled jobs — only if data needs periodic refresh.
        5. Write everything to disk and confirm the project is ready.

        Start with question 1.
        """
        if !trimmedDescription.isEmpty {
            prompt += "\n\nFor question 1, the user already wrote: \"\(trimmedDescription)\". Confirm your understanding and move directly to question 2."
        }
        return prompt
    }

    // MARK: - Defaults

    /// Default parent directory for new projects: `~/Projects` if it
    /// exists, else `~`. Matches Scarf's convention of preferring the
    /// user's `~/Projects` folder when available without forcing it.
    private static func defaultParentDirectory() -> String {
        let home = NSHomeDirectory()
        let projectsDir = home + "/Projects"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsDir, isDirectory: &isDir),
           isDir.boolValue {
            return projectsDir
        }
        return home
    }
}
