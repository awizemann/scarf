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
///
/// ## Issues are NOT single-line
/// `_cron_doctor_issues_for_job` emits `last run failed: {last_error}`,
/// and `last_error` is whatever the scheduler stored — which for a script
/// job is `cron/scheduler.py`'s `"stderr:\n" + stderr`, i.e. a full
/// Python traceback. `cron.py` interpolates that straight into the
/// `    - {issue}` f-string, so only the FIRST physical line of a
/// multi-line issue carries the bullet; the rest land at the traceback's
/// own indentation (often 0 or 2 columns).
///
/// The parse is therefore indent-based, not prefix-based:
///  - **indent 2** (`  <job_id> <name>`) — a job header, but only when it
///    can't be a traceback line (see `isPlausibleJobHeader`).
///  - **indent 4 + `- `** — the start of a new issue.
///  - **anything else** — a continuation of the issue in progress, joined
///    back onto it with a newline (verbatim, so the traceback stays
///    readable). A continuation with no issue in progress is dropped.
///
/// Getting this wrong is not cosmetic: the old prefix-based parse read
/// every traceback line as a new job header, fabricating findings under
/// bogus ids (`File`, `Traceback`) and truncating the real issue to its
/// first line.
public enum HermesCronDoctorParser {

    public static func args() -> [String] { ["cron", "doctor"] }

    /// True when `text` looks like output `cron doctor` actually produced
    /// (either sentinel), as opposed to an argparse error, a stack trace,
    /// or the empty string from a failed invocation. Callers use this to
    /// decide whether a run may be memoized or must be retried — `cron
    /// doctor` exits **1 on the normal "found issues" path**, so the exit
    /// code alone can't tell success from failure.
    public static func looksLikeDoctorOutput(_ text: String) -> Bool {
        text.split(separator: "\n").contains { raw in
            let lower = HermesCronIncidentsParser.stripANSI(String(raw))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return lower.hasPrefix("cron doctor found") || lower.hasPrefix("✓ cron doctor")
        }
    }

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
            let indent = line.prefix(while: { $0 == " " }).count

            // A blank line inside a traceback is part of the traceback;
            // outside one it's just the CLI's own spacing.
            if trimmed.isEmpty {
                if !currentIssues.isEmpty { currentIssues[currentIssues.count - 1] += "\n" }
                continue
            }

            // Issue bullet — `    - <issue>` at indent 4. Accept a deeper
            // indent too (defensive), but never indent < 4: a bullet-like
            // line at column 0/2 is traceback text, not CLI chrome.
            if indent >= 4, trimmed.hasPrefix("- ") {
                if currentID != nil {
                    currentIssues.append(String(trimmed.dropFirst(2)))
                }
                continue
            }

            // Chrome — only ever printed at indent 0 or 2. Mid-issue the
            // match tightens: a traceback can contain anything, so only
            // the CLI's verbatim sentences may interrupt one (the trailing
            // `Next:` hint is exactly that case).
            if indent <= 2, isChrome(trimmed, strict: !currentIssues.isEmpty) { continue }

            // Job header candidate: indent exactly 2, and either nothing
            // is in progress (so it can't be a continuation) or the first
            // token looks like a Hermes job id.
            if indent == 2, currentIssues.isEmpty || isPlausibleJobID(firstToken(trimmed)) {
                flush()
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let first = parts.first else { continue }
                currentID = String(first)
                currentName = parts.count > 1 ? String(parts[1]) : ""
                continue
            }

            // Everything else continues the issue in progress, verbatim
            // (original indentation preserved — it's traceback structure).
            if !currentIssues.isEmpty {
                currentIssues[currentIssues.count - 1] += "\n" + rtrim(line)
            }
        }
        flush()
        return findings.mapValues { finding in
            HermesCronDoctorFinding(
                jobID: finding.jobID,
                jobName: finding.jobName,
                issues: finding.issues.map(rtrim)
            )
        }
    }

    // MARK: - Internals

    private static func isChrome(_ trimmed: String, strict: Bool) -> Bool {
        let lower = trimmed.lowercased()
        // Printed verbatim by `cron_doctor` — safe to recognize even in
        // the middle of a traceback.
        if lower.hasPrefix("cron doctor found")
            || lower.hasPrefix("✓ cron doctor")
            || lower.hasPrefix("next: fix the listed job config") {
            return true
        }
        if strict { return false }
        // Looser prefixes, used only between findings where nothing else
        // can legitimately appear.
        return lower.hasPrefix("next:")
            || lower.hasPrefix("checked ")
            || lower.hasPrefix("no active jobs")
    }

    private static func firstToken(_ trimmed: String) -> String {
        String(trimmed.prefix(while: { $0 != " " }))
    }

    /// Can `token` be a job id rather than the first word of a traceback
    /// line that happens to sit at indent 2?
    ///
    /// `cron/jobs.py` mints ids as `uuid.uuid4().hex[:12]`, and hand-made
    /// stores use slugs like `nightly-1`. So: identifier characters only,
    /// and either a digit somewhere or a long hex run. Python traceback
    /// lines fail every clause — `File`/`Traceback`/`During`/`raise` carry
    /// no digit, and `KeyError:` / `self.run()` / `~~~~^^^` carry
    /// characters an id can't have. This check only applies while an issue
    /// is open; the first header of a block is accepted unconditionally.
    private static func isPlausibleJobID(_ token: String) -> Bool {
        guard token.count >= 3,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return false }
        if token.contains(where: { $0.isNumber }) { return true }
        return token.count >= 8 && token.allSatisfy { $0.isHexDigit }
    }

    private static func rtrim(_ s: String) -> String {
        var out = s
        while let last = out.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
            out.removeLast()
        }
        return out
    }
}
