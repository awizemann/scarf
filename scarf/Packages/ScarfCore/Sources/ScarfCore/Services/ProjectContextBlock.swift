import Foundation
#if canImport(os)
import os
#endif

/// Pure block-splice logic for the Scarf-managed region of a project's
/// `<project>/AGENTS.md`. Shared by Mac (which wraps it in
/// `ProjectAgentContextService` with template-manifest + cron-aware
/// block rendering) and ScarfGo (which renders a simpler block and
/// writes it over SFTP).
///
/// The marker contract is a cross-platform invariant — both apps must
/// produce byte-identical markers so a Mac-scaffolded block round-trips
/// through iOS and vice-versa without either side treating the other's
/// content as "missing markers."
public enum ProjectContextBlock {

    /// Load-bearing across releases. Do not change these strings
    /// without a coordinated migration — existing project AGENTS.md
    /// files on disk carry them.
    public static let beginMarker = "<!-- scarf-project:begin -->"
    public static let endMarker = "<!-- scarf-project:end -->"

    /// Errors surfaced by writers. Narrow set — most callers just log
    /// and continue; a missing project-context block is a polish
    /// degradation, not a chat-start blocker.
    public enum WriteError: Error, LocalizedError {
        case encodingFailed
        public var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Couldn't encode AGENTS.md block as UTF-8"
            }
        }
    }

    /// Splice `block` into `existing`, preserving everything outside
    /// the markers. Three cases:
    /// 1. `existing` has both markers → replace inclusive region.
    /// 2. `existing` has no markers → prepend block + blank line.
    /// 3. `existing` has only a begin marker → prepend (don't guess).
    public static func applyBlock(_ block: String, to existing: String) -> String {
        guard let beginRange = existing.range(of: beginMarker),
              let endRange = existing.range(
                of: endMarker,
                range: beginRange.upperBound..<existing.endIndex
              )
        else {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return block + "\n" }
            return block + "\n\n" + existing
        }
        var upperBound = endRange.upperBound
        while upperBound < existing.endIndex,
              existing[upperBound].isNewline {
            upperBound = existing.index(after: upperBound)
        }
        let before = String(existing[existing.startIndex..<beginRange.lowerBound])
        let after = String(existing[upperBound..<existing.endIndex])
        let prefix = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : trimmingRightNewlines(before) + "\n\n"
        let suffix = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\n"
            : "\n\n" + trimmingLeftNewlines(after)
        return prefix + block + suffix
    }

    /// Strip the Scarf-managed region from `existing`, preserving
    /// everything outside the markers byte-for-byte. Returns `existing`
    /// unchanged when there is no complete marker pair — a file with only a
    /// begin marker is not one we can bound, and guessing where the block
    /// ends would eat the user's own text.
    ///
    /// The inverse of `applyBlock`, and the reason it exists: the block
    /// names the project, its template, its cron jobs and its slash commands
    /// and is injected into every chat that opens the folder. Nothing ever
    /// removed it, so a project taken out of Scarf left an AGENTS.md that
    /// went on telling every agent about a project that isn't there — cron
    /// ids that no longer resolve, a `.scarf/` that was deleted.
    public static func removeBlock(from existing: String) -> String {
        guard let beginRange = existing.range(of: beginMarker),
              let endRange = existing.range(
                of: endMarker,
                range: beginRange.upperBound..<existing.endIndex
              )
        else { return existing }
        var upperBound = endRange.upperBound
        while upperBound < existing.endIndex, existing[upperBound].isNewline {
            upperBound = existing.index(after: upperBound)
        }
        let before = String(existing[existing.startIndex..<beginRange.lowerBound])
        let after = String(existing[upperBound..<existing.endIndex])
        if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return after
        }
        if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trimmingRightNewlines(before) + "\n"
        }
        return trimmingRightNewlines(before) + "\n\n" + trimmingLeftNewlines(after)
    }

    /// Remove the managed block from `<project>/AGENTS.md` in place.
    /// No-op — and never an error — when the file or the block is absent:
    /// this runs on the project-removal path, where refusing to finish
    /// because a markdown file was missing would be absurd.
    public static func removeBlock(
        forProjectAt projectPath: String,
        context: ServerContext
    ) throws {
        let transport = context.makeTransport()
        let agentsMdPath = projectPath + "/AGENTS.md"
        guard transport.fileExists(agentsMdPath) else { return }
        let existingData = try transport.readFile(agentsMdPath)
        let existing = String(data: existingData, encoding: .utf8) ?? ""
        let rewritten = removeBlock(from: existing)
        guard rewritten != existing else { return }
        guard let outData = rewritten.data(using: .utf8) else {
            throw WriteError.encodingFailed
        }
        try transport.writeFile(agentsMdPath, data: outData)
    }

    /// Read `<project>/AGENTS.md`, splice in the given block, write
    /// back — all via the provided context's transport. Idempotent on
    /// identical inputs.
    ///
    /// Called by ScarfGo's ChatController.startNewSession when the
    /// user picks "In project…". Mac's ProjectAgentContextService is
    /// a richer wrapper that constructs the block first, but the
    /// persistence step uses the same splice logic under the hood.
    public static func writeBlock(
        _ block: String,
        forProjectAt projectPath: String,
        context: ServerContext
    ) throws {
        let transport = context.makeTransport()
        let agentsMdPath = projectPath + "/AGENTS.md"

        if !transport.fileExists(projectPath) {
            try transport.createDirectory(projectPath)
        }

        if !transport.fileExists(agentsMdPath) {
            let data = (block + "\n").data(using: .utf8) ?? Data()
            try transport.writeFile(agentsMdPath, data: data)
            return
        }

        let existingData = try transport.readFile(agentsMdPath)
        let existing = String(data: existingData, encoding: .utf8) ?? ""
        let rewritten = applyBlock(block, to: existing)
        guard let outData = rewritten.data(using: .utf8) else {
            throw WriteError.encodingFailed
        }
        guard outData != existingData else { return }
        try transport.writeFile(agentsMdPath, data: outData)
    }

    // MARK: - Full managed block (shared Mac + iOS — single source of truth)

    /// Flat, already-resolved inputs for `renderManagedBlock`. Each
    /// platform gathers these via its own readers (Mac via
    /// `ProjectAgentContextService`, iOS via `ProjectStore`) then feeds
    /// the SAME renderer, so a Mac-scaffolded block and an iOS-scaffolded
    /// block are byte-identical for identical on-disk state — honoring the
    /// cross-platform marker invariant above.
    public struct ManagedBlockInput: Sendable {
        public let projectName: String
        public let projectPath: String
        public let templateId: String?
        public let templateVersion: String?
        /// Pre-formatted via `configFieldsLine(fields:)`.
        public let configFieldsLine: String
        /// Pre-formatted via `cronLines(from:projectId:templateId:)`.
        public let cronLines: [String]
        public let slashCommandNames: [String]
        public let kanbanTenant: String?
        public let lockFilePresent: Bool

        public init(
            projectName: String,
            projectPath: String,
            templateId: String? = nil,
            templateVersion: String? = nil,
            configFieldsLine: String,
            cronLines: [String] = [],
            slashCommandNames: [String] = [],
            kanbanTenant: String? = nil,
            lockFilePresent: Bool = false
        ) {
            self.projectName = projectName
            self.projectPath = projectPath
            self.templateId = templateId
            self.templateVersion = templateVersion
            self.configFieldsLine = configFieldsLine
            self.cronLines = cronLines
            self.slashCommandNames = slashCommandNames
            self.kanbanTenant = kanbanTenant
            self.lockFilePresent = lockFilePresent
        }
    }

    /// Render the FULL Scarf-managed block. Pure function of `input` —
    /// the single rendering source of truth for both apps. Includes
    /// project identity, template, config field NAMES (secret-safe),
    /// registered cron jobs, slash commands, Kanban tenant, and the
    /// static "Scarf platform reference" section.
    public static func renderManagedBlock(_ input: ManagedBlockInput) -> String {
        let projectPath = input.projectPath
        var lines: [String] = []
        lines.append(beginMarker)
        lines.append("## Scarf project context")
        lines.append("")
        lines.append("_Auto-generated by Scarf — do not edit between the begin/end markers._")
        lines.append("")
        lines.append("You are operating inside a Scarf project named **\"\(input.projectName)\"**. Scarf is a macOS GUI for Hermes; the user is working with this project through it. This chat session's working directory is the project's directory — path-relative tool calls resolve inside the project.")
        lines.append("")
        lines.append("- **Project directory:** `\(projectPath)`")
        lines.append("- **Dashboard:** `\(projectPath)/.scarf/dashboard.json`")

        if let id = input.templateId, let version = input.templateVersion {
            lines.append("- **Template:** `\(id)` v\(version)")
        }
        lines.append("- **Configuration fields:** \(input.configFieldsLine)")

        if input.cronLines.isEmpty {
            lines.append("- **Registered cron jobs:** (none attributed to this project)")
        } else {
            lines.append("- **Registered cron jobs:**")
            for line in input.cronLines {
                lines.append("  - \(line)")
            }
        }

        if !input.slashCommandNames.isEmpty {
            let formatted = input.slashCommandNames.sorted().map { "`/\($0)`" }.joined(separator: ", ")
            lines.append("- **Project slash commands:** \(formatted). The user invokes these via the chat slash menu; you'll see the expanded prompt as a normal user message preceded by `<!-- scarf-slash:<name> -->`.")
        }

        if let tenant = input.kanbanTenant, !tenant.isEmpty {
            lines.append("- **Kanban tenant:** `\(tenant)` — when creating Hermes Kanban tasks for this project, always pass `--tenant \(tenant)` to `hermes kanban create` so the tasks land on this project's board instead of the global \"Untagged\" pile.")
        }

        if input.lockFilePresent {
            lines.append("- **Uninstall manifest:** `\(projectPath)/.scarf/template.lock.json` (tracks files written by template install)")
        }

        // Static section — surface Scarf's feature vocabulary so the agent
        // knows what's available beyond a bare Hermes session. Doesn't
        // depend on project state, so it stays byte-identical across
        // refreshes (idempotency-critical).
        lines.append("")
        lines.append("### Scarf platform reference")
        lines.append("")
        lines.append("Some affordances available here that you wouldn't have in a bare Hermes session:")
        lines.append("")
        lines.append("- **Project tools.** When a `scarf-projects` MCP server is available to you, PREFER its tools for project registration, dashboard writes, slash commands and validation (`project_list`, `project_get`, `project_register`, `project_update_dashboard`, `project_add_slash_command`, `project_validate`) over editing Scarf's files by hand — they run the same code Scarf's UI does, validate before they write, and tell you exactly what was wrong when they refuse. Hand-editing the projects registry is the fallback for hosts without the tools, never the first choice.")
        lines.append("- **Dashboard widgets.** `<project>/.scarf/dashboard.json` renders into Scarf's Projects tab via a typed widget vocabulary (`stat`, `progress`, `text`, `table`, `chart`, `list`, `cron_status`, `log_tail`, `markdown_file`, `status_grid`, `kanban_summary`, …). Write it with `project_update_dashboard` where that tool exists. The full catalog + field schema lives in `~/.hermes/skills/scarf/scarf-template-author/SKILL.md` § Widget Catalog. The viewer auto-refreshes on file changes — no manual reload needed.")
        lines.append("- **Project slash commands.** Add one with `project_add_slash_command` where that tool exists, or author a `<project>/.scarf/slash-commands/<name>.md` file with frontmatter (`name`, `description`, optional `argumentHint` / `model` / `tags`) and a prompt body; Scarf surfaces `/<name>` in this chat's slash menu and expands the prompt before forwarding to you, wrapped in `<!-- scarf-slash:<name> -->` so you can tell expansion apart from a literal user message.")
        lines.append("- **Kanban board.** Hermes Kanban tasks created from this chat should pass `--tenant <kanban tenant>` (above) so they land on this project's per-project board, not the global \"Untagged\" pile. Tasks are also auto-stamped with the ACP `session_id` of this chat, so the project's Kanban tab can scope to \"tasks from THIS chat\" with a single toggle.")
        lines.append("- **Per-project model preset.** The user may have bound a `(model, provider)` preset to this project — `session/set_model` already applied it at session boot. Mention the active model only when relevant; the user picks presets via Scarf's right-click → \"Set Model…\".")
        lines.append("- **Typed configuration schema.** `<project>/.scarf/manifest.json` may declare `config.schema` with typed fields. Secret-typed values live in the macOS Keychain and are referenced from `config.json` via opaque URI handles, not stored inline. NEVER write a secret value to disk yourself — route Keychain reads through `ProjectConfigService.resolveSecret(_:for:)`.")
        lines.append("- **Cron jobs.** Schedule recurring work with `hermes cron create --workdir \(projectPath) …` so the job inherits this project's AGENTS.md context and resolves relative paths inside the project.")
        lines.append("- **Skills.** Hermes loads SKILL.md files from `~/.hermes/skills/`. Scarf bundles `scarf-template-author` (v2+) for project authoring, under the `scarf/` category folder; users can install more via `hermes skills install <identifier-or-https-url>` or by dropping a directory under `~/.hermes/skills/`.")
        lines.append("- **Export to template.** When the dashboard, optional schema, and AGENTS.md are stable, the user can right-click the project in Scarf → \"Export as Template…\" to produce a shareable `.scarftemplate` bundle. Authoring guidance: `~/.hermes/skills/scarf/scarf-template-author/SKILL.md`.")
        lines.append("")
        lines.append("When the user asks to scaffold, extend, or restructure this project, invoke the `scarf-template-author` skill — it documents the full widget catalog, the config-schema field types, and the export contract.")

        lines.append("")
        lines.append("Any content below this block is template- or user-authored; preserve and defer to it for project-specific behavior. Do NOT modify content inside these markers — Scarf rewrites this block on every project-scoped chat start.")
        lines.append(endMarker)

        return lines.joined(separator: "\n")
    }

    /// Secret-safe "Configuration fields" tail: comma-joined backticked
    /// field NAMES with an inline `(secret …)` hint, or "(none)" when the
    /// project declares no config schema. **Never** includes values.
    public static func configFieldsLine(fields: [(key: String, isSecret: Bool)]) -> String {
        guard !fields.isEmpty else { return "(none)" }
        return fields.map { field in
            let secretTag = field.isSecret ? " (secret — name only, value stored in Keychain)" : ""
            return "`\(field.key)`\(secretTag)"
        }.joined(separator: ", ")
    }

    /// Human-readable descriptions for cron jobs attributed to this
    /// project — via the first-class `[proj:<id>]` tag or the legacy
    /// template `[tmpl:<id>]` prefix. Empty when none match.
    public static func cronLines(
        from jobs: [HermesCronJob],
        projectId: UUID,
        templateId: String?
    ) -> [String] {
        let projPrefix = "[proj:\(projectId.uuidString)]"
        let tmplPrefix = templateId.map { "[tmpl:\($0)]" }
        return jobs
            .filter { job in
                if job.name.hasPrefix(projPrefix) { return true }
                if let tmplPrefix, job.name.hasPrefix(tmplPrefix) { return true }
                return false
            }
            .map { job in
                let scheduleDesc = job.schedule.display
                    ?? job.schedule.expression
                    ?? job.schedule.kind
                let pausedDesc = job.enabled ? "enabled" : "paused"
                return "`\(job.name)` — schedule `\(scheduleDesc)`, currently \(pausedDesc)"
            }
    }

    // MARK: - Private

    private static func trimmingRightNewlines(_ s: String) -> String {
        var result = s
        while let last = result.last, last.isNewline {
            result.removeLast()
        }
        return result
    }

    private static func trimmingLeftNewlines(_ s: String) -> String {
        var result = s
        while let first = result.first, first.isNewline {
            result.removeFirst()
        }
        return result
    }
}
