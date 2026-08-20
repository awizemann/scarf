import Foundation

/// Pure-Swift parsers for `hermes skills` CLI output. Extracted from
/// the Mac `SkillsViewModel` in v2.5 so iOS can share the same parse
/// logic — both targets call `transport.runProcess(executable: hermes…)`
/// and feed the captured stdout/stderr through these parsers.
///
/// Marked `Sendable` so they can run inside `Task.detached` blocks
/// without isolation gymnastics. All members are `nonisolated`.
public enum HermesSkillsHubParser: Sendable {

    /// Parse `hermes skills browse|search` output.
    ///
    /// Hermes emits a Rich box-drawn table with vertical bars as column
    /// separators:
    ///
    ///     │    # │ Name           │ Description            │ Source       │ Trust      │
    ///     ├──────┼────────────────┼────────────────────────┼──────────────┼────────────┤
    ///     │    1 │ 1password      │ Set up and use 1Pass…  │ official     │ ★ official │
    ///
    /// Description cells can wrap across multiple rows — the
    /// continuation rows have an empty `#` column. We join consecutive
    /// rows with the same skill by checking whether the first column
    /// (after `│`) is whitespace-only.
    public static func parseHubList(_ output: String) -> [HermesHubSkill] {
        var results: [HermesHubSkill] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw
            // Skip everything that isn't a data row. Data rows start
            // with `│` and contain multiple `│` separators. Border
            // rows (`┏`, `┡`, `├`, `└`, etc.) are drawn with `━` or
            // `─` and should be skipped.
            guard line.contains("│") else { continue }
            let cells = line
                .split(separator: "│", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Expect at least: leading empty, #, Name, Description,
            // Source, Trust, trailing empty
            guard cells.count >= 6 else { continue }

            let numCell = cells[1]
            let nameCell = cells[2]
            let descCell = cells[3]
            let sourceCell = cells[4]
            // Trust column (index 5) is informational only — we ignore
            // it in the UI.

            // Continuation row: `#` column is empty. Merge its
            // description into the last-added entry if present.
            if numCell.isEmpty {
                guard !results.isEmpty else { continue }
                let last = results.removeLast()
                let merged = [last.description, descCell]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                results.append(HermesHubSkill(
                    identifier: last.identifier,
                    name: last.name,
                    description: merged,
                    source: last.source
                ))
                continue
            }
            // Header row — first data-looking row whose number cell
            // isn't a digit.
            if Int(numCell) == nil { continue }
            // Empty name cell shouldn't happen but guard anyway.
            guard !nameCell.isEmpty else { continue }

            // Identifier: `hermes skills browse` shows the short name
            // in the Name column. For install we need the full
            // identifier like `<source>/<name>`. The CLI accepts just
            // the name for official hub, so we use that as the install
            // target.
            let source = sourceCell
                .replacingOccurrences(of: "★", with: "")
                .trimmingCharacters(in: .whitespaces)
            results.append(HermesHubSkill(
                identifier: nameCell,
                name: nameCell,
                description: descCell,
                source: source
            ))
        }
        return results
    }

    /// Parse `hermes skills check` output for available updates. Format
    /// is undocumented; we look for `→` (U+2192) or `->` arrow markers
    /// between version strings.
    public static func parseUpdateList(_ output: String) -> [HermesSkillUpdate] {
        var results: [HermesSkillUpdate] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("→") || line.contains("->") else { continue }
            let marker = line.contains("→") ? "→" : "->"
            let parts = line.components(separatedBy: marker)
            guard parts.count == 2 else { continue }
            let left = parts[0].trimmingCharacters(in: .whitespaces)
            let available = parts[1].trimmingCharacters(in: .whitespaces)
            let leftTokens = left
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard leftTokens.count >= 2 else { continue }
            let identifier = leftTokens[0]
            let current = leftTokens[leftTokens.count - 1]
            results.append(HermesSkillUpdate(
                identifier: identifier,
                currentVersion: current,
                availableVersion: available
            ))
        }
        return results
    }

    /// Parse `hermes skills update` output into an accurate report.
    ///
    /// Hermes v0.20.4 stopped overwriting skills that have local edits.
    /// `do_update` (`hermes_cli/skills_hub.py`) now prints, per skipped
    /// skill:
    ///
    ///     Skipping: reddit — you have local edits (update would overwrite them).
    ///
    /// then a final tally that EXCLUDES the skipped ones:
    ///
    ///     Updated 2 skill(s).
    ///     1 skill(s) kept your local edits: reddit.
    ///     Overwrite with: hermes skills update <name> --force
    ///
    /// Pre-v0.20.4 hosts print only `Updated N skill(s).` (N = every
    /// entry, nothing is ever skipped) — those lines simply don't exist,
    /// so `skipped` comes back empty and callers render exactly as before.
    ///
    /// Rich strips its own markup when stdout isn't a TTY, so we match the
    /// plain text. Long lines can soft-wrap at Rich's 80-column default;
    /// the per-skill `Skipping:` lines are the authoritative source (the
    /// name sits well before any wrap point) and the trailing summary's
    /// name list is merged in as a belt-and-braces second source.
    public static func parseUpdateReport(_ output: String) -> HermesSkillsUpdateReport {
        var updatedCount: Int?
        var skipped: [String] = []

        func appendSkipped(_ name: String) {
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,\"'"))
            guard !clean.isEmpty, !skipped.contains(clean) else { return }
            skipped.append(clean)
        }

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Per-skill skip notice. The strict `Skipping:` prefix keeps
            // us clear of the unrelated `Skipping entry with no
            // identifier: …` line the sync path can emit.
            if line.hasPrefix(Self.skipPrefix) {
                let rest = line.dropFirst(Self.skipPrefix.count).trimmingCharacters(in: .whitespaces)
                if let name = rest.split(separator: " ", maxSplits: 1).first {
                    appendSkipped(String(name))
                }
                continue
            }

            // `Updated N skill(s).` — present on every Hermes version.
            if updatedCount == nil,
               line.hasPrefix(Self.updatedPrefix),
               line.contains(Self.skillCountSuffix) {
                let rest = line.dropFirst(Self.updatedPrefix.count)
                let digits = rest.prefix { $0.isNumber }
                if let n = Int(digits) { updatedCount = n }
                continue
            }

            // `N skill(s) kept your local edits: a, b.`
            if let range = line.range(of: Self.keptMarker) {
                let names = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: ",")
                for name in names { appendSkipped(String(name)) }
                continue
            }
        }

        return HermesSkillsUpdateReport(updatedCount: updatedCount ?? 0, skipped: skipped)
    }

    private static let skipPrefix = "Skipping:"
    private static let updatedPrefix = "Updated "
    private static let skillCountSuffix = "skill(s)"
    private static let keptMarker = "skill(s) kept your local edits:"
}

// MARK: - Public model types

/// Outcome of a `hermes skills update` run.
///
/// `updatedCount` is what Hermes actually rewrote; `skipped` are the
/// skills it left alone because the user edited them on disk. On
/// pre-v0.20.4 hosts `skipped` is always empty.
public struct HermesSkillsUpdateReport: Sendable, Equatable {
    public let updatedCount: Int
    public let skipped: [String]

    public init(updatedCount: Int, skipped: [String]) {
        self.updatedCount = updatedCount
        self.skipped = skipped
    }
}

/// A single search/browse result from a skill registry. Mirrors the
/// shape `SkillsViewModel` had on Mac before the v2.5 ScarfCore promotion.
public struct HermesHubSkill: Identifiable, Sendable, Equatable {
    public var id: String { identifier }
    public let identifier: String      // e.g. "openai/skills/skill-creator"
    public let name: String
    public let description: String
    public let source: String          // "official" | "skills-sh" | etc.

    public init(
        identifier: String,
        name: String,
        description: String,
        source: String
    ) {
        self.identifier = identifier
        self.name = name
        self.description = description
        self.source = source
    }
}

/// A local skill that has an upstream version available.
public struct HermesSkillUpdate: Identifiable, Sendable, Equatable {
    public var id: String { identifier }
    public let identifier: String
    public let currentVersion: String
    public let availableVersion: String

    public init(
        identifier: String,
        currentVersion: String,
        availableVersion: String
    ) {
        self.identifier = identifier
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
    }
}
