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

    /// Render a minimal Scarf-managed block for iOS ScarfGo usage.
    /// Omits the template-manifest + cron-job sections that the Mac
    /// service fills in — ScarfGo v1 doesn't surface those concepts
    /// yet. The marker + identity headers match the Mac output byte-
    /// for-byte where the content overlaps, so a project scaffolded
    /// on iOS round-trips cleanly through the Mac.
    public static func renderMinimalBlock(projectName: String, projectPath: String) -> String {
        var lines: [String] = []
        lines.append(beginMarker)
        lines.append("## Scarf project context")
        lines.append("")
        lines.append("_Auto-generated by Scarf — do not edit between the begin/end markers._")
        lines.append("")
        lines.append("You are operating inside a Scarf project named **\"\(projectName)\"**. This chat session's working directory is the project's directory — path-relative tool calls resolve inside the project.")
        lines.append("")
        lines.append("- **Project directory:** `\(projectPath)`")
        lines.append("- **Dashboard:** `\(projectPath)/.scarf/dashboard.json`")
        lines.append("")
        lines.append("Any content below this block is template- or user-authored; preserve and defer to it for project-specific behavior. Do NOT modify content inside these markers — Scarf rewrites this block on every project-scoped chat start.")
        lines.append(endMarker)
        return lines.joined(separator: "\n")
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
