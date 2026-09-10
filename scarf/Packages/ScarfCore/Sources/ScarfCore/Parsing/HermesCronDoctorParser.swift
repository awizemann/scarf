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

    /// How loudly one issue should read.
    ///
    /// v0.21.1 split the delivery story in two: `last_status ==
    /// "delivery_failed"` no longer emits `last run failed:` at all (the
    /// agent run succeeded — only the delivery didn't), and a NEW issue
    /// reports a delivery that was acked without evidence
    /// (`hermes_cli/cron.py:498-500`). "Unverified" is not a failure: the
    /// adapter accepted the message and simply returned no receipt, so it
    /// renders as a note rather than a warning alongside issues that mean
    /// something is actually broken.
    public enum IssueSeverity: Sendable, Equatable {
        case problem
        case unverified
    }

    /// Verbatim prefix of the v0.21.1 delivery-unverified issue.
    static let unverifiedIssuePrefix = "last delivery unverified"

    public static func severity(of issue: String) -> IssueSeverity {
        issue.lowercased().hasPrefix(unverifiedIssuePrefix) ? .unverified : .problem
    }

    /// Issues that mean something is broken — the count the banner headlines,
    /// so an unverified-delivery note never reads as a failure.
    public var problemIssues: [String] {
        issues.filter { Self.severity(of: $0) == .problem }
    }

    public var unverifiedIssues: [String] {
        issues.filter { Self.severity(of: $0) == .unverified }
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
///  - **indent 2** (`  <job_id> <name>`) — a job header. The id is
///    whichever id in `knownJobIDs` is the longest prefix of the line at a
///    token boundary, because a job id may itself CONTAIN SPACES (an
///    id-keyed `jobs.json` contributes its map key verbatim,
///    `cron/jobs.py::load_jobs` v2026.9.7 :1271). Without a roster — or for
///    an id Scarf hasn't loaded — it falls back to the first token, guarded
///    so it can't be a traceback line (see `isPlausibleJobID`).
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
    public static func parse(
        text: String,
        knownJobIDs: Set<String> = []
    ) -> [String: HermesCronDoctorFinding] {
        // Longest first, so `nightly backup` wins over a hypothetical
        // `nightly` when both are real ids and the header is ambiguous.
        let candidates = knownJobIDs.sorted { $0.count > $1.count }
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

            // Job header, decided against the ids Scarf already holds:
            // the id is whichever KNOWN id is the longest prefix of the
            // header followed by a space or end-of-line. This is the only
            // way to read an id that CONTAINS a space — an id-keyed
            // `jobs.json` from an external tool contributes its map KEY as
            // the id (`cron/jobs.py::load_jobs`, v2026.9.7 :1271), and
            // nothing sanitizes it, so `nightly backup` is a legal id that
            // splitting on the first space attributes to a job called
            // `nightly` with the name `backup`.
            if indent == 2, let id = knownIDPrefix(of: trimmed, candidates: candidates) {
                flush()
                currentID = id
                currentName = String(trimmed.dropFirst(id.count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // No id roster to match against (or an id Scarf hasn't loaded):
            // fall back to the shape heuristic on the first token.
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

    /// The longest id in `candidates` that `trimmed` starts with at a
    /// token boundary (end-of-line, or a space before the job name).
    /// `candidates` must already be sorted longest-first.
    static func knownIDPrefix(of trimmed: String, candidates: [String]) -> String? {
        for id in candidates where !id.isEmpty {
            guard trimmed.hasPrefix(id) else { continue }
            let rest = trimmed.dropFirst(id.count)
            if rest.isEmpty || rest.first == " " { return id }
        }
        return nil
    }

    private static func firstToken(_ trimmed: String) -> String {
        String(trimmed.prefix(while: { $0 != " " }))
    }

    /// Can `token` be a job id rather than the first word of a traceback
    /// line that happens to sit at indent 2?
    ///
    /// The header grammar is `  {id} {name}` (`hermes_cli/cron.py:531`), so
    /// the id is one token of identifier characters. Hermes mints ids as
    /// `uuid.uuid4().hex[:12]`, but an id-keyed `jobs.json` written by an
    /// external tool contributes its KEY as the id (`cron/jobs.py:1271`) —
    /// any string at all, `nightly-backup` included. Requiring a DIGIT (the
    /// original rule) swallowed exactly those: the header was read as a
    /// continuation of the previous job's traceback, so the job vanished
    /// from the findings and its issue was attributed to the wrong job.
    ///
    /// So: identifier characters only, plus one shape marker — a digit, a
    /// `-`/`_` separator, or a long hex run. Python traceback lines fail
    /// every clause: `File`, `Traceback`, `During`, `raise` are bare
    /// lowercase/capitalised words with no separator and no digit, and
    /// `KeyError:`, `self.run()`, `~~~~^^^` carry characters the charset
    /// rejects outright.
    ///
    /// Residual limit, deliberate: a single bare word (`nightly`) is still
    /// not accepted MID-TRACEBACK, because nothing distinguishes it from
    /// `Traceback`. The first header of a block is accepted unconditionally,
    /// so such a job is only mis-read when it directly follows a job whose
    /// issue text contains a traceback.
    private static func isPlausibleJobID(_ token: String) -> Bool {
        guard token.count >= 3,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return false }
        if token.contains(where: { $0.isNumber }) { return true }
        // A separator is a shape no traceback keyword has.
        if token.contains("-") || token.contains("_") { return true }
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
