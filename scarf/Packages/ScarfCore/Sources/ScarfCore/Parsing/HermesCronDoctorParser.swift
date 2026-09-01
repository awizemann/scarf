import Foundation

/// Per-job findings from `hermes cron doctor` (Hermes v0.21+; callers
/// gate on `HermesCapabilities.hasCronDoctor`).
public struct HermesCronDoctorFinding: Sendable, Equatable, Identifiable {
    public let jobID: String
    /// The job name as the CLI printed it (`(unnamed)` when unset). Kept
    /// for diagnostics only — the UI matches rows by `jobID`.
    public let jobName: String
    public let issues: [String]

    public var id: String { jobID }

    public init(jobID: String, jobName: String, issues: [String]) {
        self.jobID = jobID
        self.jobName = jobName
        self.issues = issues
    }
}

/// Argv builder + text parser for `hermes cron doctor`.
///
/// The command is read-only and exits **1 when it finds issues** — a
/// non-zero exit is the normal "found problems" path, NOT a failure, so
/// callers must parse stdout regardless of exit code. Output
/// (`hermes_cli/cron.py::cron_doctor`):
///
/// ```
/// Cron doctor found 3 issue(s) across 2 job(s):
///
///   <job_id> <name>
///     - <issue>
///     - <issue>
///
/// Next: fix the listed job config, then run `hermes cron doctor` again.
/// ```
///
/// and the clean case `✓ Cron doctor found no issues` + `Checked N
/// active job(s).`. Only jobs WITH issues are printed, and disabled jobs
/// are never checked (`list_jobs(include_disabled=False)`).
public enum HermesCronDoctorParser {

    public static func args() -> [String] { ["cron", "doctor"] }

    /// Parse the findings block into `jobID → finding`. Chrome lines
    /// (summary header, `Next:` hint, the clean-run sentinel) are
    /// skipped; an issue bullet with no preceding job header is dropped.
    public static func parse(text: String) -> [String: HermesCronDoctorFinding] {
        var findings: [String: HermesCronDoctorFinding] = [:]
        var currentID: String?
        var currentName = ""
        var currentIssues: [String] = []

        func flush() {
            defer { currentID = nil; currentName = ""; currentIssues = [] }
            guard let currentID, !currentIssues.isEmpty else { return }
            findings[currentID] = HermesCronDoctorFinding(
                jobID: currentID, jobName: currentName, issues: currentIssues
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = HermesCronIncidentsParser.stripANSI(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Issue bullet.
            if trimmed.hasPrefix("- ") {
                if currentID != nil {
                    currentIssues.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                }
                continue
            }

            // Chrome.
            let lower = trimmed.lowercased()
            if lower.hasPrefix("cron doctor found")
                || lower.hasPrefix("✓ cron doctor")
                || lower.hasPrefix("next:")
                || lower.hasPrefix("checked ")
                || lower.hasPrefix("no active jobs") {
                continue
            }

            // Job header: `<job_id> <name…>`. Name may be empty in a
            // future release; the id is the only load-bearing token.
            flush()
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            currentID = String(first)
            currentName = parts.count > 1 ? String(parts[1]) : ""
        }
        flush()
        return findings
    }
}
