import Foundation

/// Parsed view of `hermes curator status` text + the on-disk
/// `~/.hermes/skills/.curator_state` JSON.
///
/// Hermes v0.12 doesn't ship a `--json` flag for `curator status` — the
/// CLI writes a human-readable report. CuratorViewModel parses the text
/// output for the human-readable bits ("least recently active", "most
/// active") and reads the state file directly for last-run metadata.
public struct HermesCuratorStatus: Sendable, Equatable {
    public enum RunState: String, Sendable, Equatable {
        case enabled
        case paused
        case disabled
        case unknown
    }

    public let state: RunState
    public let runCount: Int
    public let lastRunISO: String?         // raw timestamp string, parsed by callers
    public let lastSummary: String?        // free-text summary line
    public let lastReportPath: String?     // absolute path to <YYYYMMDD-HHMMSS>/ dir
    public let intervalLabel: String       // e.g. "every 7d"
    public let staleAfterLabel: String     // e.g. "30d unused"
    public let archiveAfterLabel: String   // e.g. "90d unused"

    public let totalSkills: Int
    public let activeSkills: Int
    public let staleSkills: Int
    public let archivedSkills: Int

    /// v0.20 provenance split from the header line
    /// `curator-managed skills: N total  (agent-created=X  bundled=Y)`.
    /// `nil` on pre-0.20 hosts that print `agent-created skills: N total`.
    public let agentCreatedSkills: Int?
    public let bundledSkills: Int?

    /// v0.20 unmanaged summary block between `pinned` and the top-5 lists:
    /// `unmanaged (no provenance marker): N total`. `nil` when absent
    /// (pre-0.20 host, or 0.20 with no unmanaged skills — Hermes omits
    /// the block entirely when the report is empty).
    public let unmanagedCount: Int?

    public let pinnedNames: [String]

    /// Top-5 lists rendered in the curator output. Each row carries the
    /// skill name + the four counters Hermes prints.
    public let leastRecentlyActive: [HermesCuratorSkillRow]
    public let mostActive: [HermesCuratorSkillRow]
    public let leastActive: [HermesCuratorSkillRow]

    public init(
        state: RunState,
        runCount: Int,
        lastRunISO: String?,
        lastSummary: String?,
        lastReportPath: String?,
        intervalLabel: String,
        staleAfterLabel: String,
        archiveAfterLabel: String,
        totalSkills: Int,
        activeSkills: Int,
        staleSkills: Int,
        archivedSkills: Int,
        agentCreatedSkills: Int? = nil,
        bundledSkills: Int? = nil,
        unmanagedCount: Int? = nil,
        pinnedNames: [String],
        leastRecentlyActive: [HermesCuratorSkillRow],
        mostActive: [HermesCuratorSkillRow],
        leastActive: [HermesCuratorSkillRow]
    ) {
        self.state = state
        self.runCount = runCount
        self.lastRunISO = lastRunISO
        self.lastSummary = lastSummary
        self.lastReportPath = lastReportPath
        self.intervalLabel = intervalLabel
        self.staleAfterLabel = staleAfterLabel
        self.archiveAfterLabel = archiveAfterLabel
        self.totalSkills = totalSkills
        self.activeSkills = activeSkills
        self.staleSkills = staleSkills
        self.archivedSkills = archivedSkills
        self.agentCreatedSkills = agentCreatedSkills
        self.bundledSkills = bundledSkills
        self.unmanagedCount = unmanagedCount
        self.pinnedNames = pinnedNames
        self.leastRecentlyActive = leastRecentlyActive
        self.mostActive = mostActive
        self.leastActive = leastActive
    }

    public static let empty = HermesCuratorStatus(
        state: .unknown,
        runCount: 0,
        lastRunISO: nil,
        lastSummary: nil,
        lastReportPath: nil,
        intervalLabel: "—",
        staleAfterLabel: "—",
        archiveAfterLabel: "—",
        totalSkills: 0,
        activeSkills: 0,
        staleSkills: 0,
        archivedSkills: 0,
        pinnedNames: [],
        leastRecentlyActive: [],
        mostActive: [],
        leastActive: []
    )
}

public struct HermesCuratorSkillRow: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let activityCount: Int
    public let useCount: Int
    public let viewCount: Int
    public let patchCount: Int
    public let lastActivityLabel: String   // raw label as printed (e.g. "never", "2d ago")

    public init(
        name: String,
        activityCount: Int,
        useCount: Int,
        viewCount: Int,
        patchCount: Int,
        lastActivityLabel: String
    ) {
        self.name = name
        self.activityCount = activityCount
        self.useCount = useCount
        self.viewCount = viewCount
        self.patchCount = patchCount
        self.lastActivityLabel = lastActivityLabel
    }
}

/// One row of `hermes curator list-unmanaged` (v0.20+) — a curation-
/// eligible skill with no provenance marker. Rows print as:
///
///     <name>  activity=   N  last_activity=<label>  (<marker>)
///
/// where `<marker>` is `no marker` or `created_by:null`.
public struct HermesCuratorUnmanagedSkill: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let activityCount: Int
    public let lastActivityLabel: String
    public let markerLabel: String    // raw parenthetical, e.g. "no marker"

    public init(name: String, activityCount: Int, lastActivityLabel: String, markerLabel: String) {
        self.name = name
        self.activityCount = activityCount
        self.lastActivityLabel = lastActivityLabel
        self.markerLabel = markerLabel
    }
}

/// Pure parser for `hermes curator status` stdout. Public for tests.
///
/// Format is stable enough to text-parse; we never error on missing
/// sections — we just leave the corresponding field empty so
/// CuratorView can render "—" without crashing on a future layout
/// tweak. State file overrides text-parsed values when both are present.
public enum HermesCuratorStatusParser {
    public static func parse(text: String, stateFileJSON: Data? = nil) -> HermesCuratorStatus {
        let lines = text.components(separatedBy: "\n")
        var status = HermesCuratorStatus.empty

        // Header section: `curator: ENABLED` / `runs:` / `last run:` /
        // `last summary:` / `interval:` / `stale after:` / `archive after:`
        var state = HermesCuratorStatus.RunState.unknown
        var runCount = 0
        var lastRunISO: String?
        var lastSummary: String?
        var lastReportPath: String?
        var interval = "—"
        var stale = "—"
        var archive = "—"

        // Skill counts: `agent-created skills: N total` then
        // `  active     N` / `  stale      N` / `  archived   N`
        var total = 0
        var active = 0
        var staleCount = 0
        var archived = 0
        var agentCreated: Int?
        var bundled: Int?
        var unmanaged: Int?

        var pinned: [String] = []

        // Lists: `least recently active (top 5):` / `most active (top 5):` /
        // `least active (top 5):` followed by indented row lines.
        enum Section {
            case header
            case leastRecent
            case mostActive
            case leastActive
        }
        var section = Section.header
        var leastRecent: [HermesCuratorSkillRow] = []
        var mostActiveRows: [HermesCuratorSkillRow] = []
        var leastActiveRows: [HermesCuratorSkillRow] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Section markers
            if line.hasPrefix("least recently active") {
                section = .leastRecent
                continue
            }
            if line.hasPrefix("most active") {
                section = .mostActive
                continue
            }
            if line.hasPrefix("least active") {
                section = .leastActive
                continue
            }

            // Header section single-line keys
            if line.hasPrefix("curator:") {
                let val = String(line.dropFirst("curator:".count)).trimmingCharacters(in: .whitespaces).uppercased()
                switch val {
                case "ENABLED": state = .enabled
                case "PAUSED": state = .paused
                case "DISABLED": state = .disabled
                default: state = .unknown
                }
                continue
            }
            if line.hasPrefix("runs:") {
                runCount = Int(line.dropFirst("runs:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                continue
            }
            if line.hasPrefix("last run:") {
                let val = String(line.dropFirst("last run:".count)).trimmingCharacters(in: .whitespaces)
                lastRunISO = val == "never" ? nil : val
                continue
            }
            if line.hasPrefix("last summary:") {
                let val = String(line.dropFirst("last summary:".count)).trimmingCharacters(in: .whitespaces)
                lastSummary = (val == "(none)" || val.isEmpty) ? nil : val
                continue
            }
            if line.hasPrefix("last report:") {
                let val = String(line.dropFirst("last report:".count)).trimmingCharacters(in: .whitespaces)
                lastReportPath = val.isEmpty ? nil : val
                continue
            }
            if line.hasPrefix("interval:") {
                interval = String(line.dropFirst("interval:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("stale after:") {
                stale = String(line.dropFirst("stale after:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("archive after:") {
                archive = String(line.dropFirst("archive after:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Header line, version-agnostic (never capability-gate a parser):
            //   pre-0.20: `agent-created skills: 18 total`
            //   0.20+:    `curator-managed skills: 18 total  (agent-created=0  bundled=18)`
            if line.hasPrefix("agent-created skills:") || line.hasPrefix("curator-managed skills:") {
                let after = line
                    .drop(while: { $0 != ":" })
                    .dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                if let n = Int(after.split(separator: " ").first ?? "") {
                    total = n
                }
                // Optional 0.20 provenance split: `(agent-created=X  bundled=Y)`.
                if let n = intValue(after: "agent-created=", in: after) {
                    agentCreated = n
                }
                if let n = intValue(after: "bundled=", in: after) {
                    bundled = n
                }
                section = .header
                continue
            }
            // 0.20 empty sentinel (pre-0.20 printed "no agent-created
            // skills"); either way total stays 0 — consume the line so it
            // can't be misread as a skill row.
            if line == "no curator-managed skills" || line == "no agent-created skills" {
                section = .header
                continue
            }
            // 0.20 unmanaged summary: `unmanaged (no provenance marker): 50 total`
            if line.hasPrefix("unmanaged (") {
                if let colon = line.firstIndex(of: ":") {
                    let after = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if let n = Int(after.split(separator: " ").first ?? "") {
                        unmanaged = n
                    }
                }
                section = .header
                continue
            }
            // Counts: "active     18" / "stale      0" / "archived   0"
            if let row = parseStateCountRow(line) {
                switch row.state {
                case "active":   active = row.count
                case "stale":    staleCount = row.count
                case "archived": archived = row.count
                default: break
                }
                continue
            }
            // pinned (3): foo, bar, baz
            if line.hasPrefix("pinned (") {
                if let colon = line.firstIndex(of: ":") {
                    let names = line[line.index(after: colon)...]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    pinned = names
                }
                continue
            }

            // Skill rows like:
            //   <name>  activity= N  use= N  view= N  patches= N  last_activity=<label>
            if section != .header, let parsed = parseSkillRow(line) {
                switch section {
                case .leastRecent:  leastRecent.append(parsed)
                case .mostActive:   mostActiveRows.append(parsed)
                case .leastActive:  leastActiveRows.append(parsed)
                case .header:       break
                }
            }
        }

        // Apply state-file overrides if present. The .curator_state JSON
        // is authoritative for last_run_at / last_run_summary /
        // last_report_path because those carry timestamps the text
        // output rounds.
        if let json = stateFileJSON,
           let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
            if obj["paused"] as? Bool == true { state = .paused }
            if let count = obj["run_count"] as? Int { runCount = count }
            if let lr = obj["last_run_at"] as? String { lastRunISO = lr }
            if let summary = obj["last_run_summary"] as? String, !summary.isEmpty { lastSummary = summary }
            if let path = obj["last_report_path"] as? String, !path.isEmpty { lastReportPath = path }
        }

        status = HermesCuratorStatus(
            state: state,
            runCount: runCount,
            lastRunISO: lastRunISO,
            lastSummary: lastSummary,
            lastReportPath: lastReportPath,
            intervalLabel: interval,
            staleAfterLabel: stale,
            archiveAfterLabel: archive,
            totalSkills: total,
            activeSkills: active,
            staleSkills: staleCount,
            archivedSkills: archived,
            agentCreatedSkills: agentCreated,
            bundledSkills: bundled,
            unmanagedCount: unmanaged,
            pinnedNames: pinned,
            leastRecentlyActive: leastRecent,
            mostActive: mostActiveRows,
            leastActive: leastActiveRows
        )
        return status
    }

    /// First integer immediately following `key` in `text`
    /// (e.g. `intValue(after: "bundled=", in: "(agent-created=0  bundled=18)")` → 18).
    private static func intValue(after key: String, in text: String) -> Int? {
        guard let r = text.range(of: key) else { return nil }
        let digits = text[r.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// `active     18` style row inside the skill-count block.
    private static func parseStateCountRow(_ line: String) -> (state: String, count: Int)? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2,
              ["active", "stale", "archived"].contains(parts[0]),
              let count = Int(parts[1])
        else { return nil }
        return (parts[0], count)
    }

    /// Skill-list row parser. Tolerates Hermes's whitespace-padded
    /// layout — `activity=  0` has two spaces between `=` and the
    /// number, so we can't split-on-space-then-split-on-`=`. Instead
    /// we slide a key-detection cursor across the row and grab the
    /// next non-whitespace token after each known key.
    private static func parseSkillRow(_ line: String) -> HermesCuratorSkillRow? {
        guard let activityRange = line.range(of: "activity=") else { return nil }
        let name = String(line[..<activityRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Map each known key to its value substring. Read positionally
        // by slicing between consecutive known keys — handles arbitrary
        // whitespace padding without depending on column positions.
        let knownKeys = ["activity=", "use=", "view=", "patches=", "last_activity="]
        var positions: [(key: String, range: Range<String.Index>)] = []
        for key in knownKeys {
            if let r = line.range(of: key) {
                positions.append((key, r))
            }
        }
        positions.sort { $0.range.lowerBound < $1.range.lowerBound }

        var activity = 0, use = 0, view = 0, patch = 0
        var lastActivity = ""

        for (idx, entry) in positions.enumerated() {
            let valueStart = entry.range.upperBound
            let valueEnd = idx + 1 < positions.count
                ? positions[idx + 1].range.lowerBound
                : line.endIndex
            let raw = String(line[valueStart..<valueEnd]).trimmingCharacters(in: .whitespaces)
            switch entry.key {
            case "activity=":      activity = Int(raw) ?? 0
            case "use=":           use = Int(raw) ?? 0
            case "view=":          view = Int(raw) ?? 0
            case "patches=":       patch = Int(raw) ?? 0
            case "last_activity=": lastActivity = raw
            default:               break
            }
        }
        return HermesCuratorSkillRow(
            name: name,
            activityCount: activity,
            useCount: use,
            viewCount: view,
            patchCount: patch,
            lastActivityLabel: lastActivity
        )
    }
}
