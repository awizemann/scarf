import Foundation

// MARK: - Findings

/// How much a finding matters. Ordered so a report can sort worst-first
/// and a badge can colour on the maximum.
public enum ProjectDoctorSeverity: Int, Sendable, Comparable, CaseIterable {
    /// Nothing is wrong — history worth knowing about (a quarantine copy,
    /// a rolling backup).
    case info = 0
    /// A suspicion, not a defect. Best-effort signal, may be a false positive.
    case low = 1
    /// A real inconsistency the user should resolve, but nothing is lost yet.
    case medium = 2
    /// Something is already broken or is losing data.
    case high = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One reconciliation defect found across the registry, the canonical
/// `<root>/.scarf/project.json` records, and the on-disk `.scarf/` scan.
///
/// A finding is a REPORT first. `repair` is present only when the fix goes
/// through an existing idempotent writer; everything else — duplicates,
/// malformed agent-owned sidecars — is deliberately flagged and left to the
/// user, because guessing which of two duplicate rows to delete, or
/// rewriting a file an agent owns, is not the doctor's call to make.
public struct ProjectDoctorFinding: Sendable, Identifiable, Equatable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Registry row carries no `uuid`.
        case missingRegistryUUID
        /// Registry row's `uuid` is present but is not a UUID at all — the
        /// 2026-09-02 live corruption. The salvaging decode drops the field,
        /// so this is visible only in the raw JSON.
        case invalidRegistryUUID
        /// Registry row with no `<root>/.scarf/project.json`.
        case missingRecord
        /// Record and registry row disagree on the id. The record is
        /// canonical; the index is what gets corrected.
        case recordIdMismatch
        /// A project directory on disk that the registry doesn't list.
        case orphanProjectDir
        /// Two or more registry rows at the same (normalized) path.
        case duplicatePath
        /// Two or more registry rows sharing a display name — the name is
        /// still the SwiftUI selection key.
        case duplicateName
        /// An agent-owned sidecar (`dashboard.json`, `manifest.json`,
        /// `config.json`, or an unparseable `project.json`) that doesn't
        /// parse or is oversize. REPORT-ONLY, always.
        case malformedSidecar
        /// Registry row whose root directory is gone while the host is
        /// plainly reachable.
        case deadRootPath
        /// Root directory missing AND its parent missing — almost always a
        /// transport that is down rather than a deleted project.
        case unreachableRoot
        /// A quarantine copy or rolling backup exists. History, not damage.
        case registryHistory
        /// A cron job attributed to this project runs somewhere else —
        /// consistent with a reused path adopting a previous project's jobs.
        case pathReuseSuspicion
        /// A registry row survived, but one of its optional fields held a
        /// value the decode could not read and dropped — the row's folder
        /// or archived flag. Field salvage deliberately does NOT block
        /// writes (see `RegistryLoss`), which is exactly why it needs to be
        /// SAID: the next save persists the row without that field, and
        /// nothing else in the app would ever mention it. Report-only —
        /// the value is unrecoverable, so re-setting it is the user's call.
        case registryFieldSalvaged
    }

    /// A repair, named by the existing writer it goes through. Cases carry
    /// the subject path so a repair can be applied against a FRESH registry
    /// read rather than the possibly-stale one the report was built from.
    public enum Repair: Sendable, Equatable {
        /// `ProjectStore.indexInRegistry(record)` — write the canonical
        /// record's id into its registry row.
        case reindexRegistryFromRecord(path: String)
        /// `ProjectStore.save(derive(from: row))` — write the missing
        /// record and index it.
        case writeMissingRecord(path: String)
        /// `ProjectStore.save(derive(from: synthesized row))` — register a
        /// project dir the registry doesn't list. Explicit-only.
        case adoptOrphan(path: String, name: String)
        /// `ProjectDashboardService.saveRegistry` minus this row.
        /// Destructive, explicit-only.
        case removeRegistryRow(path: String)

        /// Whether "Repair All (safe)" may run this unattended. Adoption
        /// changes what the user sees in their sidebar and removal deletes a
        /// row; both are the user's call, per finding.
        public var isSafe: Bool {
            switch self {
            case .reindexRegistryFromRecord, .writeMissingRecord: return true
            case .adoptOrphan, .removeRegistryRow: return false
            }
        }

        /// Whether applying this destroys something. Drives the confirm step.
        public var isDestructive: Bool {
            if case .removeRegistryRow = self { return true }
            return false
        }

        /// Verb for the per-finding button.
        public var actionLabel: String {
            switch self {
            case .reindexRegistryFromRecord: return "Fix Identity"
            case .writeMissingRecord: return "Create Record"
            case .adoptOrphan: return "Add to Projects"
            case .removeRegistryRow: return "Remove Row"
            }
        }
    }

    /// Stable across repeated `diagnose()` runs, so SwiftUI keeps row
    /// identity and a repair result can be matched back to its finding.
    public let id: String
    public let kind: Kind
    public let severity: ProjectDoctorSeverity
    /// One short line naming the problem.
    public let title: String
    /// One plain sentence explaining it. No jargon the user didn't choose.
    public let detail: String
    /// Display name of the project involved, when there is exactly one.
    public let projectName: String?
    /// Subject path — a project root, or a sidecar file for `malformedSidecar`.
    public let path: String?
    public let repair: Repair?
    /// How many registry rows this finding's repair will actually touch.
    ///
    /// Only ever more than 1 for `removeRegistryRow`, whose writer matches
    /// rows by NORMALIZED path: `/a/b` and `/a/b/` are two spellings of one
    /// folder, so a dead folder claimed by both is one finding whose repair
    /// removes two rows. The confirm copy is derived from this rather than
    /// assumed, because "Remove “X” from the list?" over a button that
    /// deletes two rows is the kind of quiet inaccuracy that makes a user
    /// distrust every other thing the doctor says.
    public let affectedRowCount: Int

    public init(
        id: String,
        kind: Kind,
        severity: ProjectDoctorSeverity,
        title: String,
        detail: String,
        projectName: String? = nil,
        path: String? = nil,
        repair: Repair? = nil,
        affectedRowCount: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.projectName = projectName
        self.path = path
        self.repair = repair
        self.affectedRowCount = max(1, affectedRowCount)
    }

    /// Title for the destructive confirmation, derived from what the repair
    /// will do rather than from what the single-row case used to do.
    public var confirmTitle: String {
        guard affectedRowCount == 1 else {
            return "Remove \(affectedRowCount) entries from the list?"
        }
        guard let projectName else { return "Remove this entry from the list?" }
        return "Remove “\(projectName)” from the list?"
    }

    /// Body for the destructive confirmation. Says "entry"/"entries" to
    /// match, and repeats the one reassurance that matters: nothing on disk
    /// is touched.
    public var confirmMessage: String {
        affectedRowCount == 1
            ? "This removes the entry from your projects list only. No files are deleted."
            : "\(affectedRowCount) entries point at this folder. This removes all of them from your "
                + "projects list only. No files are deleted."
    }
}

// MARK: - Repair gating

/// Why every repair is refused right now.
///
/// The doctor's repairs all end in a registry rewrite, and a rewrite of a
/// LOSSY load makes the loss permanent — the rows the decode couldn't read
/// disappear from `projects.json` for good.
///
/// This is a PRESENTATION wrapper around `RegistryLoss`, which is the one
/// definition of lossy the whole app shares (and which
/// `ProjectDashboardService.saveRegistry` enforces whether or not the
/// doctor asks). It exists only so the doctor sheet can say "repairs" where
/// the sidebar says "changes"; the cases are the loss's cases, and adding
/// one there must add one here.
///
/// Field-level salvage deliberately does NOT block: a dropped field held an
/// invalid value, and re-writing without it is exactly what the uuid repairs
/// are for. It surfaces as a `registryFieldSalvaged` FINDING instead.
public enum ProjectDoctorRepairBlock: Sendable, Equatable {
    /// The decode skipped whole rows; they are only in the file, not in
    /// anything we could write back.
    case rowsDropped(Int)
    /// The file couldn't be parsed at all and was set aside.
    case registryQuarantined(path: String)
    /// The file is there but empty or unreadable — we cannot tell "no
    /// projects" from "couldn't read your projects".
    case registryUnreadable(path: String)

    /// The doctor's view of a registry load's `loss`. `nil` in, `nil` out:
    /// nothing to block.
    public init?(_ loss: RegistryLoss?) {
        switch loss {
        case .none: return nil
        case .rowsDropped(let count, _): self = .rowsDropped(count)
        case .quarantined(let path): self = .registryQuarantined(path: path)
        case .unreadable(let path): self = .registryUnreadable(path: path)
        }
    }

    public var message: String {
        switch self {
        case .rowsDropped(let n):
            return "\(n) \(n == 1 ? "project" : "projects") in your projects file couldn't be read. Repairs are paused so saving doesn't drop \(n == 1 ? "it" : "them") permanently — fix or restore the file first."
        case .registryQuarantined(let path):
            return "Your projects file couldn't be read at all and was set aside at \(path). Repairs are paused until it's restored."
        case .registryUnreadable(let path):
            return "Your projects file at \(path) is empty or couldn't be read. Repairs are paused because Scarf can't tell an empty list from a file it failed to read — restore it from the backup beside it, or delete it to start fresh."
        }
    }
}

/// What one reconciliation pass found.
public struct ProjectDoctorReport: Sendable, Equatable {
    /// Worst-first, then stable by id.
    public var findings: [ProjectDoctorFinding]
    /// Non-nil when every repair is refused; see `ProjectDoctorRepairBlock`.
    public var repairBlock: ProjectDoctorRepairBlock?
    /// Registry rows examined — context for "0 issues across 12 projects".
    public var projectCount: Int
    public var generatedAt: Date

    public init(
        findings: [ProjectDoctorFinding],
        repairBlock: ProjectDoctorRepairBlock? = nil,
        projectCount: Int = 0,
        generatedAt: Date = Date()
    ) {
        self.findings = findings
        self.repairBlock = repairBlock
        self.projectCount = projectCount
        self.generatedAt = generatedAt
    }

    /// Findings that are actual problems (informational history excluded).
    public var issues: [ProjectDoctorFinding] { findings.filter { $0.severity > .info } }

    /// Nothing to act on. Informational history alone still counts as healthy.
    public var isHealthy: Bool { issues.isEmpty }

    /// Highest severity present, `nil` when the report is empty.
    public var worstSeverity: ProjectDoctorSeverity? { findings.map(\.severity).max() }

    /// Findings "Repair All (safe)" would run, in report order. Empty while
    /// repairs are blocked.
    public var safelyRepairable: [ProjectDoctorFinding] {
        guard repairBlock == nil else { return [] }
        return findings.filter { $0.repair?.isSafe == true }
    }

    /// Findings offering any repair, safe or explicit.
    public var repairable: [ProjectDoctorFinding] {
        guard repairBlock == nil else { return [] }
        return findings.filter { $0.repair != nil }
    }

    /// The issues that concern ONE project — its own row, its own files, or
    /// a duplicate/name clash it is party to.
    ///
    /// The report is registry-wide, so a per-project surface must filter:
    /// showing "this project needs attention" on project A because projects
    /// B and C share a name is a lie about whose problem it is.
    public func issues(forProjectPath path: String, name: String) -> [ProjectDoctorFinding] {
        issues.filter { finding in
            if finding.projectName == name { return true }
            guard let subject = finding.path else { return false }
            return subject == path || subject.hasPrefix(path + "/")
        }
    }

    /// One line for the cockpit health row.
    public var summary: String {
        if let repairBlock { return repairBlock.message }
        let count = issues.count
        guard count > 0 else {
            return projectCount == 1
                ? "1 project checked — no issues."
                : "\(projectCount) projects checked — no issues."
        }
        let fixable = safelyRepairable.count
        let noun = count == 1 ? "issue" : "issues"
        return fixable > 0
            ? "\(count) \(noun) found — \(fixable) can be repaired automatically."
            : "\(count) \(noun) found."
    }
}

// MARK: - Errors

public enum ProjectDoctorError: LocalizedError, Sendable, Equatable {
    /// A repair was attempted while repairs are blocked.
    case repairsBlocked(ProjectDoctorRepairBlock)
    /// The finding carries no repair.
    case notRepairable(String)
    /// The registry no longer holds the row this repair targets — the file
    /// changed under us between diagnose and repair.
    case rowVanished(String)
    /// The record this repair reads is gone or unreadable. Also raised when
    /// a record turned up unparseable at repair time: writing over it would
    /// destroy the only copy.
    case recordUnavailable(String)
    /// Adopting a folder would create a second project with an existing
    /// name, and the sidebar removes projects BY NAME.
    case nameTaken(String)
    /// The `project.json` found in this folder declares a DIFFERENT
    /// `rootPath`. Every writer underneath addresses a project by
    /// `record.rootPath`, so acting on it would rewrite the record and the
    /// registry row of whatever project that path belongs to.
    case recordPathMismatch(path: String, declared: String)

    public var errorDescription: String? {
        switch self {
        case .repairsBlocked(let reason):
            return reason.message
        case .notRepairable(let title):
            return "“\(title)” has to be resolved by hand."
        case .rowVanished(let path):
            return "The project at \(path) is no longer in your projects list — re-run the check."
        case .recordUnavailable(let path):
            return "Couldn't read the project record at \(path). Scarf won't replace it — that would throw away whatever it holds."
        case .nameTaken(let name):
            return "Another project is already called “\(name)”. Rename it first, then add this folder."
        case .recordPathMismatch(let path, let declared):
            return "The project file in \(path) says it belongs to \(declared). Scarf won't act on it — "
                + "that would rewrite whatever is at \(declared). Fix the “rootPath” in that file first."
        }
    }
}
