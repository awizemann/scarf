import Foundation
import os
import ScarfCore

/// Writes a Scarf-managed marker block into `<project>/AGENTS.md` so
/// that Hermes — which auto-reads `AGENTS.md` from the session's cwd
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
struct ProjectAgentContextService: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectAgentContextService")

    /// Marker strings. Load-bearing: the format must stay stable
    /// across releases so existing project AGENTS.md files continue
    /// to be recognized and rewritten cleanly.
    static let beginMarker = "<!-- scarf-project:begin -->"
    static let endMarker = "<!-- scarf-project:end -->"

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
        let block = renderBlock(for: project)
        let path = agentsMdPath(for: project)
        let transport = context.makeTransport()

        // Ensure the project directory exists — this service is the
        // first thing that touches the project dir when the user
        // scaffolds a bare project via `+` + starts a chat. Normally
        // the dir exists (registered project = dir exists); belt-
        // and-suspenders for edge cases.
        if !transport.fileExists(project.path) {
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
    ///
    /// Three cases handled:
    /// 1. Existing file has both markers → replace the inclusive
    ///    region, preserve everything outside untouched.
    /// 2. Existing file has no markers → prepend the block followed
    ///    by a two-newline separator so it reads as its own section.
    /// 3. Existing file has a begin marker but no end → we DON'T try
    ///    to be clever; treat as "no markers present" and prepend.
    ///    User intervention or a later refresh can restore shape.
    ///    The stray begin-marker is left in the file; we don't
    ///    truncate to EOF (as the memory-block installer does)
    ///    because an orphaned begin on this file is more likely
    ///    hand-typed than a corrupt Scarf write.
    nonisolated static func applyBlock(block: String, to existing: String) -> String {
        guard let beginRange = existing.range(of: beginMarker),
              let endRange = existing.range(
                of: endMarker,
                range: beginRange.upperBound..<existing.endIndex
              )
        else {
            // No well-formed Scarf block present — prepend.
            let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedExisting.isEmpty {
                return block + "\n"
            }
            return block + "\n\n" + existing
        }
        // Full span: from the begin marker through the end marker
        // (inclusive). Consumes any trailing whitespace/newlines
        // immediately following the end marker so a re-render of a
        // shorter block doesn't leave a dangling blank line.
        var upperBound = endRange.upperBound
        while upperBound < existing.endIndex,
              existing[upperBound].isNewline {
            upperBound = existing.index(after: upperBound)
        }
        let before = String(existing[existing.startIndex..<beginRange.lowerBound])
        let after = String(existing[upperBound..<existing.endIndex])
        // Preserve the leading whitespace / content structure of
        // `before` but ensure exactly one blank line separates it
        // from the new block when there IS prior content.
        let prefix = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : before.trimmingRightNewlines() + "\n\n"
        // Suffix: a blank line BEFORE the remaining content, ensuring
        // the template/user content is visually separated from the
        // Scarf block.
        let suffix = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\n"
            : "\n\n" + after.trimmingLeftNewlines()
        return prefix + block + suffix
    }

    // MARK: - Block rendering

    /// Build the Markdown block for a given project. Pure function of
    /// project state — exposed for tests that want to assert on
    /// rendered content without touching disk.
    nonisolated func renderBlock(for project: ProjectEntry) -> String {
        let templateInfo = readTemplateInfo(for: project)
        let configFieldsLine = renderConfigFieldsLine(for: project)
        let cronLines = renderCronLines(for: project, templateId: templateInfo?.id)
        let lockFilePresent = context.makeTransport().fileExists(
            project.path + "/.scarf/template.lock.json"
        )

        var lines: [String] = []
        lines.append(Self.beginMarker)
        lines.append("## Scarf project context")
        lines.append("")
        lines.append("_Auto-generated by Scarf — do not edit between the begin/end markers._")
        lines.append("")
        lines.append("You are operating inside a Scarf project named **\"\(project.name)\"**. Scarf is a macOS GUI for Hermes; the user is working with this project through it. This chat session's working directory is the project's directory — path-relative tool calls resolve inside the project.")
        lines.append("")
        lines.append("- **Project directory:** `\(project.path)`")
        lines.append("- **Dashboard:** `\(project.path)/.scarf/dashboard.json`")

        if let tpl = templateInfo {
            lines.append("- **Template:** `\(tpl.id)` v\(tpl.version)")
        }
        lines.append("- **Configuration fields:** \(configFieldsLine)")

        if cronLines.isEmpty {
            lines.append("- **Registered cron jobs:** (none attributed to this project)")
        } else {
            lines.append("- **Registered cron jobs:**")
            for line in cronLines {
                lines.append("  - \(line)")
            }
        }

        if lockFilePresent {
            lines.append("- **Uninstall manifest:** `\(project.path)/.scarf/template.lock.json` (tracks files written by template install)")
        }

        lines.append("")
        lines.append("Any content below this block is template- or user-authored; preserve and defer to it for project-specific behavior. Do NOT modify content inside these markers — Scarf rewrites this block on every project-scoped chat start.")
        lines.append(Self.endMarker)

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    nonisolated private func agentsMdPath(for project: ProjectEntry) -> String {
        project.path + "/AGENTS.md"
    }

    /// Read `<project>/.scarf/manifest.json` for template id + version.
    /// Nil when not present (bare project) or when the file is
    /// unparseable — the block still renders cleanly without the
    /// template line.
    nonisolated private func readTemplateInfo(for project: ProjectEntry) -> (id: String, version: String)? {
        let manifestPath = project.path + "/.scarf/manifest.json"
        let transport = context.makeTransport()
        guard transport.fileExists(manifestPath) else { return nil }
        guard let data = try? transport.readFile(manifestPath) else { return nil }
        guard let manifest = try? JSONDecoder().decode(ProjectTemplateManifest.self, from: data) else { return nil }
        return (id: manifest.id, version: manifest.version)
    }

    /// Build the "Configuration fields" bullet's tail. Returns a
    /// comma-joined list of backticked field names with inline type
    /// hints (`(secret)`), or the literal string "(none)" when the
    /// project has no config schema. **Never** includes values.
    nonisolated private func renderConfigFieldsLine(for project: ProjectEntry) -> String {
        let manifestPath = project.path + "/.scarf/manifest.json"
        let transport = context.makeTransport()
        guard transport.fileExists(manifestPath),
              let data = try? transport.readFile(manifestPath),
              let manifest = try? JSONDecoder().decode(ProjectTemplateManifest.self, from: data),
              let schema = manifest.config,
              !schema.fields.isEmpty
        else {
            return "(none)"
        }
        let fieldList = schema.fields.map { field -> String in
            let secretTag = field.type == .secret ? " (secret — name only, value stored in Keychain)" : ""
            return "`\(field.key)`\(secretTag)"
        }
        return fieldList.joined(separator: ", ")
    }

    /// Return a list of human-readable cron-job descriptions for jobs
    /// attributed to this project via the `[tmpl:<id>] …` name prefix.
    /// Empty array when no jobs match (either the project has no
    /// template or no jobs carry the tag).
    nonisolated private func renderCronLines(for project: ProjectEntry, templateId: String?) -> [String] {
        guard let templateId else { return [] }
        let prefix = "[tmpl:\(templateId)]"
        let jobs = HermesFileService(context: context).loadCronJobs()
        return jobs
            .filter { $0.name.hasPrefix(prefix) }
            .map { job in
                let scheduleDesc = job.schedule.display
                    ?? job.schedule.expression
                    ?? job.schedule.kind
                let pausedDesc = job.enabled ? "enabled" : "paused"
                return "`\(job.name)` — schedule `\(scheduleDesc)`, currently \(pausedDesc)"
            }
    }
}

enum ProjectAgentContextError: Error {
    case encodingFailed
}

// MARK: - String helpers (file-scoped)

private extension String {
    /// Drop trailing newlines + CRs but preserve other trailing
    /// whitespace (tabs, non-breaking spaces) that might be
    /// meaningful in some edge case.
    func trimmingRightNewlines() -> String {
        var result = self
        while let last = result.last, last.isNewline {
            result.removeLast()
        }
        return result
    }

    /// Symmetric counterpart: strip leading newlines / CRs.
    func trimmingLeftNewlines() -> String {
        var result = self
        while let first = result.first, first.isNewline {
            result.removeFirst()
        }
        return result
    }
}
