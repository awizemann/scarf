import Foundation
import os
import ScarfCore

/// Writes a Scarf-managed marker block into `<project>/AGENTS.md` so
/// that Hermes — which auto-reads `AGENTS.md` from the process cwd
/// at startup — has consistent project identity and metadata in every
/// project-scoped chat.
///
/// **Why this exists.** Hermes has no native "project" concept and ACP
/// passes only `(cwd, mcpServers)` at session create — extra params
/// are silently dropped on Hermes's side. The documented hook for
/// giving the agent context when cwd is set programmatically is the
/// auto-load of `AGENTS.md` (or `.hermes.md` / `CLAUDE.md` /
/// `.cursorrules`, in that priority) from the cwd. Scarf owns a
/// managed region of the project's AGENTS.md; template-author content
/// lives outside that region and is preserved.
///
/// **Marker contract.** The region sits between:
///
/// ```
/// <!-- scarf-project:begin -->
/// …Scarf-managed content…
/// <!-- scarf-project:end -->
/// ```
///
/// Same pattern as the v2.2 memory-block appendix — bounded, self-
/// declaring, safe to re-generate. Everything outside the markers is
/// left byte-identical across refreshes.
///
/// **Secret-safe.** The block surfaces field NAMES from `config.json`
/// (via the cached manifest's schema) but never VALUES. A rendered
/// block contains no secrets even for a project whose config.json
/// has Keychain-ref URIs.
///
/// **Refresh timing.** `ChatViewModel.startACPSession(resume:projectPath:)`
/// calls `refresh(for:)` immediately before Hermes opens the session.
/// Hermes reads AGENTS.md during session boot, so the marker block
/// must have landed on disk first. Non-blocking on failure — a
/// failed refresh logs and the chat proceeds without the block.
///
/// **Rendering is shared.** Block construction lives in ScarfCore's
/// `ProjectStore.renderAgentContextBlock` / `ProjectContextBlock` so the
/// Mac and ScarfGo (iOS) emit byte-identical blocks for identical
/// on-disk state — honoring the cross-platform marker invariant. This
/// service is the Mac-side persistence wrapper around that renderer.
struct ProjectAgentContextService: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectAgentContextService")

    /// Marker strings. Delegated to ScarfCore's `ProjectContextBlock`
    /// in M9 #4.2 so both Mac and ScarfGo use identical markers.
    nonisolated static let beginMarker = ProjectContextBlock.beginMarker
    nonisolated static let endMarker = ProjectContextBlock.endMarker

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Public

    /// Refresh (or create) the Scarf-managed block in the project's
    /// AGENTS.md. Reads current project state — template manifest,
    /// config schema, registered cron jobs — and produces a block
    /// reflecting today's truth. Idempotent: two consecutive calls
    /// with no intervening state change produce byte-identical
    /// output.
    nonisolated func refresh(for project: ProjectEntry) throws {
        // Render the managed block FROM the first-class ScarfProject —
        // the object is the structured source of truth, the block its
        // projection. Load the canonical record if it exists, otherwise
        // derive it from existing on-disk state (additive, non-fatal).
        let store = ProjectStore(context: context)
        let scarfProject = store.load(projectPath: project.path) ?? store.derive(from: project)
        let block = renderBlock(for: scarfProject)
        let path = agentsMdPath(forProjectPath: project.path)
        let transport = context.makeTransport()

        // Ensure the project directory exists — this service is the
        // first thing that touches the project dir when the user
        // scaffolds a bare project via `+` + starts a chat. Normally
        // the dir exists (registered project = dir exists); belt-
        // and-suspenders for edge cases.
        //
        // Only for a project the registry still lists. A missing dir is
        // otherwise a project that was just deleted or uninstalled out from
        // under a stale in-memory entry, and re-creating it here is the
        // first half of a resurrection: the cockpit's load-or-derive would
        // then pass `ProjectStore.save`'s `projectRootMissing` guard (the
        // dir exists again) and re-register the project — now carrying the
        // SAME id it had before deletion, since ids derive from the path.
        // That re-attaches its old `[proj:<uuid>]` cron jobs and mini-app
        // grants to a directory the user deleted.
        if !transport.fileExists(project.path) {
            let registered = ProjectDashboardService(context: context)
                .loadRegistry()
                .projects
                .contains { $0.path == project.path }
            guard registered else {
                throw ProjectAgentContextError.projectDirectoryMissing(project.path)
            }
            try transport.createDirectory(project.path)
        }

        if !transport.fileExists(path) {
            // Fresh AGENTS.md with just our block + a trailing
            // newline so editors render it cleanly.
            let data = (block + "\n").data(using: .utf8) ?? Data()
            try transport.writeFile(path, data: data)
            Self.logger.info("created AGENTS.md with Scarf block for \(project.name, privacy: .public)")
            return
        }

        // Read existing, splice in the new block.
        let existingData = try transport.readFile(path)
        let existing = String(data: existingData, encoding: .utf8) ?? ""
        let rewritten = Self.applyBlock(block: block, to: existing)
        guard let outData = rewritten.data(using: .utf8) else {
            throw ProjectAgentContextError.encodingFailed
        }
        // Skip the write when nothing changed — avoids unnecessary
        // file-watcher churn. Matches what disk snapshot shows.
        guard outData != existingData else { return }
        try transport.writeFile(path, data: outData)
        Self.logger.info("refreshed Scarf block in AGENTS.md for \(project.name, privacy: .public)")
    }

    // MARK: - Marker splice (testable in isolation)

    /// Core text transform: given an existing file and a freshly-
    /// rendered block, return the file with the block spliced in.
    /// Kept as a thin forwarder so pre-existing callers + tests keep
    /// working. The logic lives in ScarfCore now (M9 #4.2).
    nonisolated static func applyBlock(block: String, to existing: String) -> String {
        ProjectContextBlock.applyBlock(block, to: existing)
    }

    // MARK: - Block rendering

    /// Build the Markdown block for a given project. Thin Mac-side
    /// forwarder to ScarfCore's shared renderer — exposed (and kept) so
    /// `ProjectAgentContextServiceTests` can assert on rendered content
    /// without touching disk, and so the iOS app produces byte-identical
    /// output from the same `ProjectStore.renderAgentContextBlock`.
    nonisolated func renderBlock(for project: ScarfProject) -> String {
        ProjectStore(context: context).renderAgentContextBlock(for: project)
    }

    // MARK: - Helpers

    nonisolated private func agentsMdPath(forProjectPath projectPath: String) -> String {
        projectPath + "/AGENTS.md"
    }
}

enum ProjectAgentContextError: LocalizedError {
    case encodingFailed
    /// The project's directory is gone and the registry no longer lists it —
    /// refusing to re-create it (see `refresh`). Every caller treats a failed
    /// refresh as non-fatal, so the chat still starts, just without the block.
    case projectDirectoryMissing(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Couldn't encode the Scarf project block."
        case .projectDirectoryMissing(let path):
            return "Project directory no longer exists at \(path); refusing to re-create it."
        }
    }
}
