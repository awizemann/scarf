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
    public enum WriteError: Error, LocalizedError, Equatable {
        case encodingFailed
        /// The file is stat-confirmed and two reads of it failed. Writing
        /// the block would replace prose nobody has seen.
        case refusedUnreadable(path: String)
        /// The bytes are there and are NOT valid UTF-8. They were read, so
        /// they are not "unreadable" in the transport sense — but they are
        /// not text we can splice, and `String(data:encoding:) ?? ""` used
        /// to turn them into an empty document that the splice then
        /// published as a block-only file. Refused instead.
        case refusedUndecodableText(path: String)

        public var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Couldn't encode AGENTS.md block as UTF-8"
            case let .refusedUnreadable(path):
                return "\(path) exists but couldn't be read; refusing to replace it with a Scarf block."
            case let .refusedUndecodableText(path):
                return "\(path) is not valid UTF-8 text; refusing to replace it with a Scarf block."
            }
        }
    }

    /// The house cap (32 MB), matching every other hand-authored file
    /// `GuardedTextFile` guards.
    ///
    /// This was `Int.max` on the grounds that AGENTS.md is the user's own
    /// prose rather than an index we decode, and that quarantining it is not
    /// ours to do. The second half still holds — and it is now free, because
    /// since GW-F5 an over-cap file is refused on the `stat`, UNREAD, with
    /// no `.corrupt-` copy made. What the first half never justified is an
    /// UNBOUNDED allocation from an agent-writable file on a phone (GW-F5 /
    /// SEC F3): `Int.max` also skips the stat probe entirely, so the only
    /// way to learn the file was multi-gigabyte was to hold it. No real
    /// AGENTS.md is anywhere near 32 MB; one that is gets a refusal instead
    /// of a jetsam.
    static let maxAgentsBytes = GuardedTextFile.defaultMaxBytes

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
    ///
    /// **Guarded (GW-E2c).** The sibling `writeBlock` below has had the
    /// proof discipline since W1; this half was left behind, and "the guard
    /// belongs to the FILE, applied by whichever writer someone audited" is
    /// exactly the disease this phase exists to end. It used to open with a
    /// bare `fileExists` (inference — a dropped SSH round-trip answers
    /// `false` and the removal silently does nothing) and then splice a read
    /// that had no stat+retry proof and no `.bak`: a truncated-but-successful
    /// read that still carried both markers republished the truncation over
    /// the user's project instructions.
    ///
    /// Now it goes through `GuardedTextFile`, the same guard `writeBlock`'s
    /// policy was factored into — proof of damage, a refusal on unreadable
    /// or non-UTF-8 bytes, and a one-deep `AGENTS.md.bak` of whatever gets
    /// replaced (the same `.bak` naming `writeBlock` produces, because it is
    /// literally the same publisher).
    ///
    /// - Returns: whether bytes were actually REWRITTEN. Callers used to
    ///   answer this for themselves by comparing a `try?` read taken before
    ///   against one taken after (GW-F2, audit DI M4) — two unguarded reads
    ///   whose failures both read as "nothing changed". The publisher knows;
    ///   it now says so.
    @discardableResult
    public static func removeBlock(
        forProjectAt projectPath: String,
        context: ServerContext
    ) throws -> Bool {
        let transport = context.makeTransport()
        // The block may live in whichever context file Hermes loads (S11-F1),
        // not only AGENTS.md. Without a listing (transport down) fall back to
        // AGENTS.md alone, where every earlier build put it.
        let names = ((try? transport.listDirectory(projectPath)).map { entries in
            // Case-insensitively on the Mac, where Hermes's `CLAUDE.md` opens
            // `Claude.md` too; exact names on a remote host.
            entries.filter { entry in
                contextFileNames.contains {
                    transport.isRemote ? $0 == entry : $0.caseInsensitiveCompare(entry) == .orderedSame
                }
            }
        }) ?? ["AGENTS.md"]
        var rewrote = false
        for name in names {
            if try removeBlock(fromFileAt: projectPath + "/" + name, transport: transport) {
                rewrote = true
            }
        }
        return rewrote
    }

    static func removeBlock(fromFileAt agentsMdPath: String, transport: any ServerTransport) throws -> Bool {
        let label = (agentsMdPath as NSString).lastPathComponent
        let guarded = GuardedTextFile(transport: transport, label: label)
        let loaded: GuardedTextFile.Loaded
        do {
            loaded = try guarded.load(agentsMdPath, maxBytes: maxAgentsBytes)
        } catch let refusal as GuardedTextFile.Refusal {
            switch refusal {
            case .unreadable(let damaged, _):
                throw WriteError.refusedUnreadable(path: damaged)
            case .notUTF8:
                // Bytes we hold but can't decode are left ALONE, exactly as
                // before: the managed block cannot be inside them, so there
                // is nothing to remove and nothing to report.
                return false
            }
        }
        // Absent is a no-op, not an error — see the doc comment.
        guard loaded.exists else { return false }
        let rewritten = removeBlock(from: loaded.text)
        guard rewritten != loaded.text else { return false }
        try guarded.write(rewritten, to: agentsMdPath, after: loaded)
        return true
    }

    /// Read `<project>/AGENTS.md`, splice in the given block, write
    /// back — all via the provided context's transport. Idempotent on
    /// identical inputs.
    ///
    /// Called by ScarfGo's ChatController.startNewSession when the
    /// user picks "In project…". Mac's ProjectAgentContextService is
    /// a richer wrapper that constructs the block first, but the
    /// persistence step uses the same splice logic under the hood.
    /// **Why this is guarded (P8 DI-C2).** This runs on EVERY project-scoped
    /// chat start, on Mac and iOS, against the user's own AGENTS.md — the
    /// most valuable file Scarf writes and the only one that never had a
    /// `.bak`. It used to open with `if !transport.fileExists(agentsMdPath)
    /// { write block-only }`: one dropped SSH/SFTP round-trip made that
    /// false and the user's whole file became the Scarf block. The second
    /// half of the same bug was `String(data:encoding:.utf8) ?? ""` — a
    /// single non-UTF-8 byte collapsed the document to empty and the splice
    /// republished it block-only.
    ///
    /// Now: PROOF, not inference (`GuardedJSONStore.inspect` — stat-confirm
    /// plus a retried read), a refusal when the file is provably there and
    /// unreadable, a refusal when the bytes aren't text, and a one-deep
    /// `AGENTS.md.bak` of whatever gets replaced.
    public static func writeBlock(
        _ block: String,
        forProjectAt projectPath: String,
        context: ServerContext
    ) throws {
        let transport = context.makeTransport()
        let survey = try surveyContextFiles(forProjectAt: projectPath, transport: transport)
        let target = survey.target
        try writeBlock(
            block,
            toFileAt: projectPath + "/" + target,
            afterFrontmatter: hermesMDNames.contains(target),
            transport: transport
        )
        // S11-F1 repair. Earlier Scarf builds always wrote AGENTS.md, which
        // shadowed the project's own CLAUDE.md / .cursorrules. A copy of the
        // block outside the target is now stale: a file that holds nothing
        // but Scarf's block is Scarf's own and is removed (only AGENTS.md /
        // agents.md — the names Scarf ever created); any other file just
        // loses the block and keeps the user's text.
        for file in survey.files where file.name != target && file.hasBlock {
            let path = projectPath + "/" + file.name
            if !file.hasUserContent && agentsMDNames.contains(file.name) {
                // Re-read right before deleting: only a file that still holds
                // nothing but Scarf's block goes.
                let now = try GuardedTextFile(transport: transport, label: file.name)
                    .load(path, maxBytes: maxAgentsBytes)
                guard now.exists else { continue }
                if removeBlock(from: now.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try transport.removeFile(path)
                } else {
                    _ = try removeBlock(fromFileAt: path, transport: transport)
                }
            } else {
                _ = try removeBlock(fromFileAt: path, transport: transport)
            }
        }
    }

    // MARK: - Which file Hermes loads (S11-F1)

    /// Hermes loads exactly ONE project-context type from the session cwd,
    /// first non-empty wins: `.hermes.md`/`HERMES.md` → `AGENTS.md`/`agents.md`
    /// → `CLAUDE.md`/`claude.md` → `.cursorrules` + `.cursor/rules/*.mdc`
    /// (`agent/prompt_builder.py:1653-1664, 1746-1747` @ v2026.9.24; the same
    /// `or` chain at `:588-591` @ v2026.3.23, below Scarf's v0.6.0 floor, so
    /// every supported host behaves this way). Empty or whitespace-only files
    /// fall through (`_read_context_file` strips, `:1576-1584`).
    ///
    /// Writing the block into a fresh AGENTS.md next to a CLAUDE.md therefore
    /// made Hermes drop the user's CLAUDE.md. The block goes into the file
    /// Hermes actually loads instead; AGENTS.md is created only when the
    /// project has no context file of its own.
    static let hermesMDNames = [".hermes.md", "HERMES.md"]
    static let agentsMDNames = ["AGENTS.md", "agents.md"]
    public static let contextFileNames = hermesMDNames + agentsMDNames + ["CLAUDE.md", "claude.md", ".cursorrules"]

    struct ContextFile: Equatable {
        let name: String
        let hasBlock: Bool
        /// Non-blank text outside Scarf's markers — what Hermes would load
        /// if Scarf's block weren't there.
        let hasUserContent: Bool
    }

    struct ContextSurvey: Equatable {
        /// Context files present in the project directory, in Hermes's
        /// priority order, under their exact on-disk names.
        let files: [ContextFile]
        /// Non-empty `.cursor/rules/*.mdc` files exist (loaded together
        /// with `.cursorrules`).
        let hasCursorRulesDir: Bool
        /// A parent directory up to the git root holds an `.hermes.md` /
        /// `HERMES.md` or an `AGENTS*.md`. Hermes walks up for those
        /// (`_find_hermes_md`, `_agents_md_candidates`, prompt_builder.py
        /// :139-148, :1602-1625 @ v2026.9.24), so the project's own
        /// CLAUDE.md / .cursorrules is not what loads, and moving the block
        /// there would hide it. Such projects keep the AGENTS.md behaviour.
        var ancestorContext = false

        /// The file the block belongs in: the highest-priority file that
        /// already carries the user's own context, else AGENTS.md.
        var target: String {
            let agents = files.first(where: { agentsMDNames.contains($0.name) })?.name ?? "AGENTS.md"
            if ancestorContext {
                return files.first(where: { hermesMDNames.contains($0.name) && $0.hasUserContent })?.name ?? agents
            }
            if let owner = files.first(where: \.hasUserContent) { return owner.name }
            if hasCursorRulesDir { return ".cursorrules" }
            // Keep an existing block-only AGENTS.md / agents.md where it is.
            return agents
        }
    }

    /// Reads the project's context files once. Names come from one
    /// directory listing, so `AGENTS.md` and `agents.md` on a
    /// case-insensitive volume are never counted as two files.
    static func surveyContextFiles(
        forProjectAt projectPath: String,
        transport: any ServerTransport
    ) throws -> ContextSurvey {
        let listing: [String]
        do {
            listing = try transport.listDirectory(projectPath)
        } catch let error as TransportError where error.isNoSuchFile
                    || (!transport.isRemote && !FileManager.default.fileExists(atPath: projectPath)) {
            // A project directory that isn't there yet has no context files;
            // the write creates it. Any other failure stops here: guessing
            // "no files" could put a new AGENTS.md over the user's CLAUDE.md.
            _ = error
            listing = []
        }
        // Hermes opens fixed names (`cwd / "CLAUDE.md"`); on the Mac's
        // case-insensitive volumes that also opens `Claude.md`. A remote
        // Linux host is case-sensitive, so there the name must match exactly.
        func onDisk(_ name: String) -> String? {
            if listing.contains(name) { return name }
            guard !transport.isRemote else { return nil }
            return listing.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        var files: [ContextFile] = []
        var seen = Set<String>()
        for candidate in contextFileNames {
            guard let name = onDisk(candidate), seen.insert(name.lowercased()).inserted || transport.isRemote,
                  !files.contains(where: { $0.name == name })
            else { continue }
            let path = projectPath + "/" + name
            let loaded: GuardedTextFile.Loaded
            do {
                loaded = try GuardedTextFile(transport: transport, label: name)
                    .load(path, maxBytes: maxAgentsBytes)
            } catch let refusal as GuardedTextFile.Refusal {
                // Can't tell whether it carries the user's context, so we
                // can't tell whether writing elsewhere would shadow it.
                switch refusal {
                case .unreadable(let damaged, _): throw WriteError.refusedUnreadable(path: damaged)
                case .notUTF8: throw WriteError.refusedUndecodableText(path: path)
                }
            }
            guard loaded.exists else { continue }
            let hasBlock = loaded.text.contains(beginMarker)
            let outside = removeBlock(from: loaded.text)
            files.append(ContextFile(
                name: name,
                hasBlock: hasBlock,
                hasUserContent: !outside.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
        }
        var hasCursorRulesDir = false
        if onDisk(".cursor") != nil {
            let rulesDir = projectPath + "/.cursor/rules"
            let mdc: [String]
            do {
                mdc = try transport.listDirectory(rulesDir).filter { $0.hasSuffix(".mdc") }
            } catch let error as TransportError where error.isNoSuchFile
                        || (!transport.isRemote && !FileManager.default.fileExists(atPath: rulesDir)) {
                _ = error
                mdc = []
            }
            hasCursorRulesDir = mdc.contains { (transport.stat(rulesDir + "/" + $0)?.size ?? 0) > 0 }
        }
        var survey = ContextSurvey(files: files, hasCursorRulesDir: hasCursorRulesDir)
        survey.ancestorContext = try ancestorHasContext(projectPath: projectPath, transport: transport)
        return survey
    }

    /// Whether a parent directory, up to the nearest one holding `.git`,
    /// has a `.hermes.md`/`HERMES.md` or `AGENTS*.md` Hermes would load
    /// ahead of the project's CLAUDE.md. One batched stat for the whole
    /// walk; an untrusted answer refuses rather than guessing.
    static func ancestorHasContext(projectPath: String, transport: any ServerTransport) throws -> Bool {
        var dirs: [String] = []
        var dir = (projectPath as NSString).standardizingPath
        while true {
            dirs.append(dir)
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        let names = hermesMDNames + ["AGENTS.override.md"] + agentsMDNames
        var paths: [String] = []
        for d in dirs { paths.append(d + "/.git"); paths += names.map { d + "/" + $0 } }
        guard let stats = transport.statAll(paths) else {
            throw WriteError.refusedUnreadable(path: projectPath)
        }
        // No git root: Hermes looks at the project directory only.
        guard let rootIndex = dirs.firstIndex(where: { stats[$0 + "/.git"] != nil }), rootIndex > 0 else {
            return false
        }
        return dirs[1...rootIndex].contains { d in
            names.contains { (stats[d + "/" + $0]?.size ?? 0) > 0 }
        }
    }

    /// Put the block after a leading `---` YAML frontmatter instead of above
    /// it. Hermes strips frontmatter from `.hermes.md` only when the file
    /// STARTS with `---` (`_strip_yaml_frontmatter`, prompt_builder.py:151-155
    /// @ v2026.9.24), so prepending would turn it into prompt text.
    static func applyBlockAfterFrontmatter(_ block: String, to existing: String) -> String {
        guard !existing.contains(beginMarker),
              existing.hasPrefix("---"),
              let close = existing.range(of: "\n---", range: existing.index(existing.startIndex, offsetBy: 3)..<existing.endIndex)
        else { return applyBlock(block, to: existing) }
        let lineEnd = existing[close.upperBound...].firstIndex(of: "\n") ?? existing.endIndex
        let head = String(existing[existing.startIndex..<lineEnd])
        let body = String(existing[lineEnd...])
        return head + "\n\n" + applyBlock(block, to: body)
    }

    /// The guarded splice into one file (P8 DI-C2 discipline, unchanged).
    private static func writeBlock(
        _ block: String,
        toFileAt agentsMdPath: String,
        afterFrontmatter: Bool,
        transport: any ServerTransport
    ) throws {
        let label = (agentsMdPath as NSString).lastPathComponent
        let guarded = GuardedJSONStore(transport: transport, label: label)
        var inspection = guarded.inspect(agentsMdPath, maxBytes: maxAgentsBytes)

        // Zero bytes is damage to a JSON sidecar (Scarf never writes an
        // empty one). An empty AGENTS.md is just an empty markdown file a
        // person made, and it has nothing to lose — so it is writable, and
        // refusing forever on it would be the degradation, not the guard.
        if case .unreadable = inspection.state, inspection.bytes?.isEmpty == true {
            inspection = GuardedJSONStore.Inspection(state: .absent, bytes: nil)
        }

        switch inspection.state {
        case .unreadable(let damaged):
            throw WriteError.refusedUnreadable(path: damaged)
        case .quarantined:
            // Since GW-F5 an over-cap file arrives as `.unreadable` above
            // (refused on the stat, never read), so this is reached only
            // through a decode-shaped quarantine. Same verdict: refuse
            // rather than replace bytes we already decided were unusable.
            throw WriteError.refusedUnreadable(path: agentsMdPath)
        case .absent:
            // `GuardedJSONStore.write` mkdir -p's the parent, so the old
            // `fileExists(projectPath)`-then-create dance is gone with the
            // rest of the inference.
            guard let data = (block + "\n").data(using: .utf8) else {
                throw WriteError.encodingFailed
            }
            try guarded.write(data, to: agentsMdPath, after: inspection)
        case .present:
            let existingData = inspection.bytes ?? Data()
            guard let existing = String(data: existingData, encoding: .utf8) else {
                throw WriteError.refusedUndecodableText(path: agentsMdPath)
            }
            let rewritten = afterFrontmatter
                ? applyBlockAfterFrontmatter(block, to: existing)
                : applyBlock(block, to: existing)
            guard let outData = rewritten.data(using: .utf8) else {
                throw WriteError.encodingFailed
            }
            guard outData != existingData else { return }
            try guarded.write(outData, to: agentsMdPath, after: inspection)
        }
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
        /// The project's stable id — the key of the `[proj:<id>]` cron name
        /// prefix every Scarf project surface attributes jobs by. `nil`
        /// keeps the old prefix-less cron line.
        public let projectId: UUID?

        public init(
            projectName: String,
            projectPath: String,
            templateId: String? = nil,
            templateVersion: String? = nil,
            configFieldsLine: String,
            cronLines: [String] = [],
            slashCommandNames: [String] = [],
            kanbanTenant: String? = nil,
            lockFilePresent: Bool = false,
            projectId: UUID? = nil
        ) {
            self.projectId = projectId
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
        lines.append("- **Per-project model preset.** The user may have bound a `(model, provider)` preset to this project — Scarf applies it with `session/set_model` when the chat opens, and if Hermes refuses it the chat runs on the config.yaml default model instead. Mention the active model only when relevant; the user picks presets via Scarf's right-click → \"Chat Settings…\".")
        lines.append("- **Typed configuration schema.** `<project>/.scarf/manifest.json` may declare `config.schema` with typed fields. Secret-typed values live in the macOS Keychain and are referenced from `config.json` via opaque URI handles, not stored inline. NEVER write a secret value to disk yourself — route Keychain reads through `ProjectConfigService.resolveSecret(_:for:)`.")
        if let projectId = input.projectId {
            // Scarf attributes a job to a project ONLY by this name prefix
            // (`cronLines` above, the cockpit's cron panel, archive's
            // pause). Hermes stores `--name` as given (`cron/jobs.py:1804,1811`
            // @ v2026.9.24), so a job the agent names any other way runs
            // but never shows up as this project's.
            let prefix = "[proj:\(projectId.uuidString)]"
            lines.append("- **Cron jobs.** Schedule recurring work with `hermes cron create --name \"\(prefix) <short label>\" --workdir \"\(projectPath)\" \"<schedule>\" \"<prompt>\"` so the job inherits this project's AGENTS.md context and resolves relative paths inside the project. Always start the name with `\(prefix) ` exactly: Scarf attributes cron jobs to this project only by that prefix (the list above, the project's cron panel, pausing on archive), so a job without it is invisible here.")
        } else {
            lines.append("- **Cron jobs.** Schedule recurring work with `hermes cron create --workdir \(projectPath) …` so the job inherits this project's AGENTS.md context and resolves relative paths inside the project.")
        }
        lines.append("- **Skills.** Hermes loads SKILL.md files from `~/.hermes/skills/`. Scarf bundles `scarf-template-author` (v2+) for project authoring, under the `scarf/` category folder; users can install more via `hermes skills install <identifier-or-https-url>` or by dropping a directory under `~/.hermes/skills/`.")
        lines.append("- **Export to template.** When the dashboard, optional schema, and AGENTS.md are stable, the user can right-click the project in Scarf → \"Export as Template…\" to produce a shareable `.scarftemplate` bundle. Authoring guidance: `~/.hermes/skills/scarf/scarf-template-author/SKILL.md`.")
        lines.append("")
        lines.append("When the user asks to scaffold, extend, or restructure this project, invoke the `scarf-template-author` skill — it documents the full widget catalog, the config-schema field types, and the export contract.")

        lines.append("")
        lines.append("Any content below this block is template- or user-authored; preserve and defer to it for project-specific behavior. Do NOT modify content inside these markers — Scarf rewrites this block on every project-scoped chat start.")
        lines.append(endMarker)

        return lines.joined(separator: "\n")
    }

    // MARK: - Environment hint (Hermes >= v0.16, #142)

    /// Short project context for the `HERMES_ENVIRONMENT_HINT` env var passed
    /// to `hermes acp` — the replacement for `renderManagedBlock` on hosts
    /// where `HermesCapabilities.supportsEnvironmentHint` is true. Hermes
    /// appends it to the system prompt (`agent/prompt_builder.py:866` @
    /// v2026.6.5), so nothing is written into the project's files.
    ///
    /// Pure and deterministic: no markers, no dates, no config values (only
    /// the project name/path, Kanban tenant and project id). The long
    /// platform reference lives in the `scarf-template-author` skill instead.
    public static func renderEnvironmentHint(_ input: ManagedBlockInput) -> String {
        let path = input.projectPath
        var lines: [String] = []
        lines.append("## Scarf project")
        lines.append("")
        lines.append("This chat was opened in Scarf (a GUI for Hermes) for the project **\"\(input.projectName)\"** at `\(path)`; it is this session's working directory.")
        if let tenant = input.kanbanTenant, !tenant.isEmpty {
            lines.append("- Kanban tenant `\(tenant)`: always pass `--tenant \(tenant)` to `hermes kanban create` so tasks land on this project's board.")
        }
        if let projectId = input.projectId {
            let prefix = "[proj:\(projectId.uuidString)]"
            lines.append("- Cron jobs: start every job name with `\(prefix) ` exactly and pass `--workdir \"\(path)\"` to `hermes cron create`; Scarf attributes jobs to this project only by that prefix.")
        }
        lines.append("- Project slash-command expansions arrive as user messages wrapped in `<!-- scarf-slash:<name> -->`.")
        lines.append("- Never write a secret value to disk; secret config values live in the Keychain.")
        lines.append("- For dashboard, template, slash-command or config work, load the `scarf-template-author` skill, and prefer the `scarf-projects` MCP tools when they are available.")
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
        return jobs
            .filter { job in
                ProjectCronAttribution.isAttributed(
                    jobName: job.name, projectID: projectId, templateId: templateId
                )
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
