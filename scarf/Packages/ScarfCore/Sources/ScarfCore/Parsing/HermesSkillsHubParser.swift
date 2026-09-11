import Foundation

/// Pure-Swift parsers for `hermes skills` CLI output. Extracted from
/// the Mac `SkillsViewModel` in v2.5 so iOS can share the same parse
/// logic — both targets call `transport.runProcess(executable: hermes…)`
/// and feed the captured stdout/stderr through these parsers.
///
/// Marked `Sendable` so they can run inside `Task.detached` blocks
/// without isolation gymnastics. All members are `nonisolated`.
public enum HermesSkillsHubParser: Sendable {

    /// Parse `hermes skills browse` output.
    ///
    /// `_render_browse_page` (`hermes_cli/skills_hub.py:393-399` at
    /// `v2026.9.7`) builds a six-column Rich table:
    ///
    ///     ┏━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━┳━━━━━━━━━━━━┳━━━━━━━━━━━━━━━┓
    ///     ┃    # ┃ Name      ┃ Description   ┃ Source       ┃ Trust      ┃ Identifier    ┃
    ///     ┡━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━╇━━━━━━━━━━━━╇━━━━━━━━━━━━━━━┩
    ///     │    2 │ pdf-tools │ Split, merge  │ skills-sh    │ community  │ pdf-tools-a1b │
    ///     │      │           │ and OCR PDF   │              │            │ 2c3           │
    ///
    /// **The Identifier column is the install target, and the Name is not.**
    /// `do_install` resolves the string it is given through
    /// `_resolve_identifier`; a browse.sh row's identifier ends in a
    /// `-XXXXXX` content hash (`pdf-tools-a1b2c3` above) and a GitHub-tap
    /// row's is a `<owner>/skills/<name>` path. Installing by Name either
    /// fails or — worse — resolves to a same-named skill in a different
    /// registry. Name is kept for display only.
    ///
    /// Two wrap rules matter, and they differ per column:
    ///
    /// * Description wraps on WORD boundaries (Rich's default), so its
    ///   continuation cells are joined with a space.
    /// * Identifier is declared `overflow="fold"` (`_ident_col`,
    ///   `hermes_cli/skills_hub.py:64-69`), which is a hard character fold — the slug
    ///   above is `pdf-tools-a1b` + `2c3`, so its continuation cells are
    ///   concatenated with NOTHING between them. Joining them with a space
    ///   would produce an identifier that installs nothing.
    ///
    /// The column set is byte-identical back to `v2026.6.19` (v0.17,
    /// `hermes_cli/skills_hub.py:424-432`), so this needs no capability gate: every
    /// host Scarf supports that can browse prints an Identifier column.
    ///
    /// A row with fewer than the browse table's cells (the `skills search`
    /// table, which has no `#` column) is skipped exactly as before —
    /// that path goes through `parseSearchJSON`.
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
            // Leading empty, #, Name, Description, Source, Trust,
            // Identifier, trailing empty — eight fields for the six
            // columns. Anything shorter is not the browse table.
            guard cells.count >= 8 else { continue }

            let numCell = cells[1]
            let nameCell = cells[2]
            let descCell = cells[3]
            let sourceCell = cells[4]
            // Trust column (index 5) is informational only — we ignore
            // it in the UI.
            let identCell = cells[6]

            // Continuation row: `#` column is empty. Merge its cells into
            // the last-added entry, each column by its own wrap rule.
            if numCell.isEmpty {
                guard !results.isEmpty else { continue }
                let last = results.removeLast()
                let merged = [last.description, descCell]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                results.append(HermesHubSkill(
                    identifier: last.identifier + identCell,
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
            // An identifier-less row cannot be installed, and the Name is
            // not a safe substitute (the browse.sh hash, the GitHub path).
            // Drop it rather than install the wrong skill — the same rule
            // `parseSearchJSON` applies.
            guard !identCell.isEmpty else { continue }

            let source = sourceCell
                .replacingOccurrences(of: "★", with: "")
                .trimmingCharacters(in: .whitespaces)
            results.append(HermesHubSkill(
                identifier: identCell,
                name: nameCell,
                description: descCell,
                source: source
            ))
        }
        return results
    }

    /// Parse `hermes skills search --json` output.
    ///
    /// `do_search(..., as_json=True)` (`hermes_cli/skills_hub.py`) prints
    /// `json.dumps([...], indent=2)` — a top-level ARRAY of objects with
    /// exactly five string keys:
    ///
    ///     [{"name": …, "identifier": …, "source": …,
    ///       "trust_level": …, "description": …}]
    ///
    /// This is the only shape that carries the full `identifier`. The
    /// table path can't: `skills search` renders `Name | Description |
    /// Source | Trust | Identifier` with **no `#` column**, so
    /// `parseHubList` — written for `skills browse`, which has one —
    /// dropped every row, and even when it didn't it used the Name cell
    /// as the install target.
    ///
    /// Returns `nil` (not `[]`) when the payload can't be read, so a
    /// caller can fall back to the table parser instead of rendering
    /// "no results" over a host that answered something else. An empty
    /// search legitimately prints `[]`, which decodes to `[]`.
    ///
    /// `trust_level` is parsed but not modelled: the hub UI shows the
    /// source, not the trust tier, exactly as the table path did.
    public static func parseSearchJSON(_ output: String) -> [HermesHubSkill]? {
        // Hermes prints the array on stdout; Scarf's runner concatenates
        // stdout+stderr, and an INFO/warning line can precede it. Slice
        // from the first `[` to the last `]` rather than demanding that
        // the whole buffer be JSON.
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8)
        else { return nil }
        guard let rows = try? JSONDecoder().decode([SearchRow].self, from: data) else { return nil }
        return rows.compactMap { row in
            // The identifier is the install target; a row without one is
            // unusable, and the name is NOT a safe substitute for a
            // browse-sh slug. Drop it rather than install the wrong skill.
            let identifier = row.identifier.trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty else { return nil }
            return HermesHubSkill(
                identifier: identifier,
                name: row.name.isEmpty ? identifier : row.name,
                description: row.description,
                source: row.source
            )
        }
    }

    /// Decoding shape of one `skills search --json` row. Every field is
    /// optional-tolerant: a future Hermes that stops emitting one of them
    /// degrades that column rather than failing the whole parse.
    private struct SearchRow: Decodable {
        let name: String
        let identifier: String
        let source: String
        let description: String

        private enum CodingKeys: String, CodingKey {
            case name, identifier, source, description
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            identifier = (try? c.decode(String.self, forKey: .identifier)) ?? ""
            source = (try? c.decode(String.self, forKey: .source)) ?? ""
            description = (try? c.decode(String.self, forKey: .description)) ?? ""
        }
    }

    /// Parse `hermes skills check` output.
    ///
    /// The old implementation hunted for `→` between two version strings.
    /// **Hermes has never printed one.** `do_check`
    /// (`hermes_cli/skills_hub.py:806-808` at `v2026.9.7`; the same three
    /// columns at `v2026.6.19:993-996`) renders a Rich table titled
    /// `Skill Updates` with `Name | Source | Status`, and the status is one
    /// of five words produced by `check_for_skill_updates`
    /// (`tools/skills_hub_install.py:251-303`):
    ///
    ///     ┏━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━┓
    ///     ┃ Name          ┃ Source    ┃ Status           ┃
    ///     ┡━━━━━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━┩
    ///     │ 1password     │ official  │ update_available │
    ///     │ pdf-tools     │ skills-sh │ up_to_date       │
    ///
    /// Hermes carries no version numbers here at all — the comparison is a
    /// content hash (`bundle_content_hash`, `:300`), so there is nothing
    /// to render as "1.0.0 → 1.1.0". Every row is returned, status and
    /// all; `SkillsViewModel` splits the actionable `update_available`
    /// rows (the only ones `do_update` acts on, `hermes_cli/skills_hub.py:847`) from
    /// the three fault statuses, which are diagnostics the user has to fix
    /// by hand.
    ///
    /// A status Scarf does not know fails `HermesSkillUpdateStatus(rawValue:)`
    /// — there is no `.unknown` case — and the ROW IS SKIPPED (`:225`) rather
    /// than badged, so a future Hermes word never renders as an available
    /// update.
    public static func parseUpdateList(_ output: String) -> [HermesSkillUpdate] {
        var results: [HermesSkillUpdate] = []
        for raw in output.components(separatedBy: "\n") {
            guard raw.contains("│") else { continue }
            let cells = raw
                .split(separator: "│", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Leading empty, Name, Source, Status, trailing empty.
            guard cells.count >= 5 else { continue }
            let name = cells[1]
            let source = cells[2]
            // The Status cell is the row key: it rejects the header row
            // (`Status`), the title line, and any continuation row a
            // wrapped Name/Source could produce, without guessing.
            guard let status = HermesSkillUpdateStatus(rawValue: cells[3]) else { continue }
            guard !name.isEmpty else { continue }
            results.append(HermesSkillUpdate(identifier: name, source: source, status: status))
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
        var noUpdatesAvailable = false
        var attemptedCount = 0
        var installedCount = 0
        var failureDetail: String?

        func appendSkipped(_ name: String) {
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,\"'"))
            guard !clean.isEmpty, !skipped.contains(clean) else { return }
            skipped.append(clean)
        }

        for line in HermesCLIVerdict.significantLines(output) {

            // `do_update` prints this and returns when nothing is actionable
            // (hermes_cli/skills_hub.py:849). Exit 0 with nothing else is then correct,
            // not a silent refusal.
            if line.hasPrefix(Self.noUpdatesLine) {
                noUpdatesAvailable = true
                continue
            }

            // `Updating: <name>` (:864) is an ATTEMPT — it is printed before
            // `do_install` runs, so it proves intent, never success.
            if line.hasPrefix(Self.attemptPrefix) {
                attemptedCount += 1
                continue
            }

            // `Installed: <path>` (:720) is the only HONEST per-skill success
            // line: `do_install` prints it after `install_from_quarantine`
            // returned. Anchored for the same reason `installOutcome` anchors
            // it — the Tier 1 advisory (:704) quotes SKILL.md text first.
            if HermesCLIVerdict.unglyphed(line).hasPrefix(Self.installedPrefix) {
                installedCount += 1
                continue
            }

            // The FIRST real refusal. Deliberately `skillsUpdateFailure`,
            // not `skillsInstallFailure`: `do_update` calls
            // `do_install(force: True)` (hermes_cli/skills_hub.py:868), which prints
            // `Warning: '<name>' is already installed at …` (:682) for every
            // skill it updates — including the ones that succeed — before it
            // ever checks `force` (:683). Matching that made a failed update
            // quote a benign warning instead of the reason.
            if failureDetail == nil,
               HermesCLIMarkers.skillsUpdateFailure.contains(where: { line.contains($0) }) {
                failureDetail = line
            }

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

        return HermesSkillsUpdateReport(
            updatedCount: updatedCount ?? 0,
            skipped: skipped,
            noUpdatesAvailable: noUpdatesAvailable,
            attemptedCount: attemptedCount,
            installedCount: installedCount,
            failureDetail: failureDetail
        )
    }

    private static let skipPrefix = "Skipping:"
    private static let updatedPrefix = "Updated "
    private static let skillCountSuffix = "skill(s)"
    private static let keptMarker = "skill(s) kept your local edits:"
    private static let noUpdatesLine = HermesCLIMarkers.skillsUpdateNoUpdates
    private static let attemptPrefix = HermesCLIMarkers.skillsUpdateAttempt
    private static let installedPrefix = HermesCLIMarkers.skillsInstallSuccess[0]
}

// MARK: - Public model types

/// Outcome of a `hermes skills update` run.
///
/// `updatedCount` is what Hermes actually rewrote; `skipped` are the
/// skills it left alone because the user edited them on disk. On
/// pre-v0.20.4 hosts `skipped` is always empty.
public struct HermesSkillsUpdateReport: Sendable, Equatable {
    /// `N` from `Updated N skill(s).` (`hermes_cli/skills_hub.py:872`). This counts
    /// ATTEMPTS, not successes: it is `len(updates) - len(skipped_local)`,
    /// computed from the list `do_update` decided to walk and printed
    /// unconditionally after the loop, whatever each `do_install` did. Kept
    /// for continuity; prefer `installedCount` for a verdict.
    public let updatedCount: Int
    public let skipped: [String]
    /// `do_update` printed `No updates available.` (`:849`) — a legitimate
    /// no-op, distinct from "it printed nothing we recognise".
    public let noUpdatesAvailable: Bool
    /// `Updating: <name>` lines (`:864`) — one per skill it tried.
    public let attemptedCount: Int
    /// `Installed: <path>` lines (`:720`) — one per skill `do_install`
    /// actually landed. The honest success count.
    public let installedCount: Int
    /// The first refusal line any nested `do_install` printed, if one did.
    public let failureDetail: String?

    public init(
        updatedCount: Int,
        skipped: [String],
        noUpdatesAvailable: Bool = false,
        attemptedCount: Int = 0,
        installedCount: Int = 0,
        failureDetail: String? = nil
    ) {
        self.updatedCount = updatedCount
        self.skipped = skipped
        self.noUpdatesAvailable = noUpdatesAvailable
        self.attemptedCount = attemptedCount
        self.installedCount = installedCount
        self.failureDetail = failureDetail
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

/// One row of `hermes skills check`.
///
/// `identifier` is the lock-file skill NAME — which is what
/// `hermes skills update <name>` takes (`hermes_cli/skills_hub.py:847`, keyed off
/// `entry["name"]`). It is deliberately NOT the hub identifier: the update
/// path resolves through the lock file, not through a registry slug.
public struct HermesSkillUpdate: Identifiable, Sendable, Equatable {
    public var id: String { identifier }
    public let identifier: String
    /// Registry the skill was installed from, as recorded in the lock file.
    public let source: String
    public let status: HermesSkillUpdateStatus

    public init(identifier: String, source: String, status: HermesSkillUpdateStatus) {
        self.identifier = identifier
        self.source = source
        self.status = status
    }
}

/// The five `status` words `check_for_skill_updates` can emit
/// (`tools/skills_hub_install.py:277-302` at `v2026.9.7`). `orphaned` and
/// `invalid_install` arrived after `v2026.6.19`, where only the other three
/// exist — an older host simply never emits them, so no gate is needed.
public enum HermesSkillUpdateStatus: String, Sendable, Equatable, CaseIterable {
    /// The upstream bundle hashes differently from what is installed.
    case updateAvailable = "update_available"
    case upToDate = "up_to_date"
    /// The lock-file entry's directory is gone or is not a directory.
    case orphaned
    /// No adapter matching the recorded source could fetch the identifier.
    case unavailable
    /// The recorded `install_path` does not resolve at all.
    case invalidInstall = "invalid_install"

    /// Only `update_available` is something `hermes skills update` acts on.
    public var isActionable: Bool { self == .updateAvailable }

    /// Human wording for the three fault statuses, shown next to the row.
    public var faultDescription: String? {
        switch self {
        case .updateAvailable, .upToDate:
            return nil
        case .orphaned:
            return String(
                localized: "Installed directory is missing — remove the stale entry with hermes skills uninstall.")
        case .unavailable:
            return String(localized: "Its source registry did not answer, so no update could be checked.")
        case .invalidInstall:
            return String(localized: "The lock file records an install path that cannot be resolved.")
        }
    }
}
