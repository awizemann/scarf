import Foundation
import os
import ScarfCore

/// Creates a Scarf-standard project from scratch — a minimal directory
/// tree with a placeholder `dashboard.json` + a stub `AGENTS.md` (just
/// the Scarf-managed marker block) — and registers it. The
/// counterpart to `ProjectTemplateInstaller`: that one synthesizes a
/// project from a `.scarftemplate` plan; this one synthesizes a bare
/// shell that the agent fills in conversationally via the
/// `scarf-template-author` skill.
///
/// **Why this exists.** `AddProjectSheet` registers an existing
/// directory but doesn't create one; `ProjectTemplateInstaller`
/// creates a directory but only from a manifest. Neither produces a
/// fresh, hand-rolled, Scarf-standard project.
///
/// **What lands on disk.**
/// ```
/// <parent>/<slug>/
/// ├── .scarf/
/// │   └── dashboard.json    # placeholder — single text widget
/// └── AGENTS.md             # marker block only; refresh() populates it
/// ```
///
/// No `manifest.json` — scratch projects don't have a config schema,
/// so the Configuration sheet correctly degrades when missing.
/// No `template.lock.json` — there's no template install to undo.
struct ProjectScaffolder: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectScaffolder")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Public

    /// Scaffold a new project at `<parentDir>/<slug>` and register it.
    /// On any failure after the project dir is created, deletes the
    /// dir and rethrows so the user isn't left with a half-created
    /// project that doesn't show in the sidebar.
    nonisolated func scaffold(
        name: String,
        slug: String,
        parentDir: String,
        description: String?
    ) throws -> ProjectEntry {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedParent = Self.normalizeDirectoryPath(parentDir)
        let cleanedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedName.isEmpty else { throw ProjectScaffolderError.invalidName }
        guard Self.isValidSlug(cleanedSlug) else {
            throw ProjectScaffolderError.invalidSlug(cleanedSlug)
        }

        let transport = context.makeTransport()

        // 1. Validate parent + collisions.
        guard transport.fileExists(cleanedParent) else {
            throw ProjectScaffolderError.parentDirMissing(cleanedParent)
        }
        let projectDir = cleanedParent + "/" + cleanedSlug
        if transport.fileExists(projectDir) {
            throw ProjectScaffolderError.projectDirExists(projectDir)
        }

        let dashboardService = ProjectDashboardService(context: context)
        let registry = dashboardService.loadRegistry()
        if registry.projects.contains(where: { $0.name == cleanedName }) {
            throw ProjectScaffolderError.nameAlreadyRegistered(cleanedName)
        }
        if registry.projects.contains(where: { $0.path == projectDir }) {
            throw ProjectScaffolderError.pathAlreadyRegistered(projectDir)
        }

        // 2. Create project + .scarf/ dir.
        do {
            try transport.createDirectory(projectDir + "/.scarf")
        } catch {
            // No partial state to clean up — createDirectory is the
            // first write. Surface the error directly.
            throw ProjectScaffolderError.createFailed(error.localizedDescription)
        }

        // From here on, on any failure, we clean up the project dir
        // before rethrowing so the user can retry without bumping
        // into the collision check.
        do {
            // 3. Write placeholder dashboard.json.
            let dashboardData = try Self.makePlaceholderDashboard(
                name: cleanedName,
                description: cleanedDescription
            )
            // UNGUARDED-WRITE(C): first write into a freshly created, collision-checked project dir.
            try transport.unguardedWriteFile(
                projectDir + "/.scarf/dashboard.json",
                data: dashboardData
            )

            // 4. Write AGENTS.md with just the marker block — the
            // refresh() call below populates between the markers.
            let agentsMd = ProjectContextBlock.beginMarker + "\n"
                + ProjectContextBlock.endMarker + "\n"
            // UNGUARDED-WRITE(C): first write into a freshly created, collision-checked project dir.
            try transport.unguardedWriteFile(
                projectDir + "/AGENTS.md",
                data: Data(agentsMd.utf8)
            )

            // 5. Mint the stable id and write the first-class
            //    ScarfProject record. `ProjectStore.save` writes the
            //    canonical `.scarf/project.json` AND indexes the project
            //    into the registry carrying the UUID — replacing the old
            //    manual registry append. A scratch project starts with
            //    no bindings beyond its single host materialization.
            let projectID = UUID()
            let entry = ProjectEntry(name: cleanedName, path: projectDir, uuid: projectID)
            let scarfProject = ScarfProject(
                id: projectID,
                name: cleanedName,
                rootPath: projectDir,
                hostBindings: [
                    ScarfProject.HostBinding(
                        serverId: context.id.uuidString,
                        rootPath: projectDir,
                        materializedAt: Date()
                    )
                ]
            )
            try ProjectStore(context: context).save(scarfProject)

            // 6. Populate the marker block with project identity.
            // Non-fatal — the chat handoff calls refresh() again
            // anyway via startACPSession's project-prep step. Logging
            // the failure here is enough. `refresh` now renders from the
            // ScarfProject record written in step 5.
            do {
                try ProjectAgentContextService(context: context).refresh(for: entry)
            } catch {
                Self.logger.warning(
                    "couldn't populate AGENTS.md marker block for \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            Self.logger.info(
                "scaffolded project \(cleanedName, privacy: .public) at \(projectDir, privacy: .public)"
            )
            return entry
        } catch {
            // Roll back the project dir. `LocalTransport.removeFile` is
            // backed by `FileManager.removeItem` which is recursive for
            // directories, so this cleans the dir + its `.scarf/` child
            // in one call on local. SSH's `rm -f` is non-recursive, but
            // the wizard's NSOpenPanel only browses local filesystems
            // anyway — remote scaffolding isn't a supported entry point
            // today. Best-effort either way: a failed cleanup logs but
            // doesn't mask the original failure.
            do {
                try transport.removeFile(projectDir)
            } catch {
                Self.logger.warning(
                    "cleanup after scaffold failure left files at \(projectDir, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
    }

    // MARK: - Slug helpers

    /// Default slug derivation from a project's display name. Used
    /// by the wizard to pre-fill the editable "Folder Name" field.
    /// Lowercases, replaces whitespace runs with `-`, strips any
    /// character outside `[a-z0-9-]`, collapses `--` → `-`, trims
    /// leading/trailing `-`.
    nonisolated static func suggestedSlug(from name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                slug.append(c)
                lastWasDash = false
            } else if c.isWhitespace || c == "-" || c == "_" || c == "." {
                if !lastWasDash && !slug.isEmpty {
                    slug.append("-")
                    lastWasDash = true
                }
            }
            // Other characters (emoji, punctuation) silently dropped.
        }
        // Trim trailing dash.
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// Validate a slug: at least one character, every character in
    /// `[a-z0-9-]`, no leading/trailing `-`, no consecutive `--`.
    nonisolated static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        guard !slug.hasPrefix("-"), !slug.hasSuffix("-") else { return false }
        if slug.contains("--") { return false }
        for scalar in slug.unicodeScalars {
            let c = Character(scalar)
            let isLowerAlpha = ("a"..."z").contains(c)
            let isDigit = ("0"..."9").contains(c)
            let isDash = c == "-"
            if !(isLowerAlpha || isDigit || isDash) {
                return false
            }
        }
        return true
    }

    // MARK: - Dashboard placeholder

    nonisolated static func makePlaceholderDashboard(
        name: String,
        description: String?
    ) throws -> Data {
        let placeholderWidget = DashboardWidget(
            type: "text",
            title: "Configure this project",
            content: """
            This project was just scaffolded by Scarf. \
            Chat with the agent to add widgets, schedule jobs, and write \
            instructions for future sessions. The `scarf-template-author` \
            skill knows the project standard end-to-end.
            """,
            format: "markdown"
        )
        let section = DashboardSection(
            title: "Setup",
            columns: 1,
            widgets: [placeholderWidget]
        )
        let dashboard = ProjectDashboard(
            version: 1,
            title: name,
            description: description?.isEmpty == false ? description : nil,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            theme: nil,
            sections: [section]
        )

        // Pretty-print so the file is readable when the user
        // opens it in an editor, matches the dashboard.json
        // shape produced by template installs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(dashboard)
    }

    // MARK: - Helpers

    /// Strip a single trailing `/` from a path so subsequent
    /// `parent + "/" + slug` joins don't produce a `//` segment.
    nonisolated static func normalizeDirectoryPath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}

enum ProjectScaffolderError: Error, LocalizedError {
    case invalidName
    case invalidSlug(String)
    case parentDirMissing(String)
    case projectDirExists(String)
    case nameAlreadyRegistered(String)
    case pathAlreadyRegistered(String)
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Project name can't be empty."
        case .invalidSlug(let s):
            return "Folder name \"\(s)\" must be lowercase letters, numbers, and dashes only — no leading/trailing or doubled dashes."
        case .parentDirMissing(let p):
            return "Parent directory doesn't exist: \(p)"
        case .projectDirExists(let p):
            return "A folder already exists at \(p). Pick a different name."
        case .nameAlreadyRegistered(let n):
            return "A project named \"\(n)\" is already registered."
        case .pathAlreadyRegistered(let p):
            return "A project at \(p) is already registered."
        case .createFailed(let msg):
            return "Couldn't create the project directory: \(msg)"
        }
    }
}
