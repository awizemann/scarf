import Foundation

/// One durable cron execution attempt from `hermes cron runs` (v0.20+,
/// caller gates on `HermesCapabilities.hasCronRuns`).
public struct HermesCronRun: Sendable, Equatable, Identifiable {
    /// Execution id — a uuid4 hex string in practice.
    public let id: String
    /// One of `claimed / running / completed / failed / unknown`
    /// (the DB CHECK constraint's closed set), or whatever a future
    /// Hermes prints — the parser doesn't validate the value.
    public let status: String
    public let jobID: String
    public let source: String
    /// ISO-8601 claim timestamp, verbatim from the CLI.
    public let claimedAt: String
    /// Indented follow-up line printed for failed/unknown attempts.
    public let error: String?

    public init(id: String, status: String, jobID: String, source: String, claimedAt: String, error: String?) {
        self.id = id
        self.status = status
        self.jobID = jobID
        self.source = source
        self.claimedAt = claimedAt
        self.error = error
    }
}

/// Parser + argv builder for `hermes cron runs [job_id] [--limit N]`.
///
/// The CLI has **no `--json` flag** (verified against v0.20 source:
/// `hermes_cli/cron.py::cron_runs`), so we parse the fixed text row
/// format it prints:
///
/// ```
/// <id>  <status padded to 9>  job=<job_id>  source=<source>  <claimed_at>
///     <error>                                    ← optional, indented
/// ```
///
/// plus the empty sentinel `No cron execution attempts recorded.`.
public enum HermesCronRunsParser {

    // MARK: - Argv builder

    /// `["cron", "runs", (job_id), ("--limit", N)]`. `--limit` is clamped
    /// to the CLI's documented 1–500 range; nil omits the flag.
    public static func args(jobID: String? = nil, limit: Int? = nil) -> [String] {
        var args = ["cron", "runs"]
        if let jobID, !jobID.isEmpty { args.append(jobID) }
        if let limit { args += ["--limit", String(min(max(limit, 1), 500))] }
        return args
    }

    // MARK: - Parser

    /// Parse the text listing. The empty sentinel (and blank output)
    /// folds to `[]`. Unrecognizable non-indented lines are skipped
    /// rather than aborting the whole parse — one weird row shouldn't
    /// blank the history panel.
    public static func parse(text: String) -> [HermesCronRun] {
        var runs: [HermesCronRun] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Indented continuation → error detail for the previous row.
            if line.first == " " || line.first == "\t" {
                if var last = runs.popLast() {
                    let detail = line.trimmingCharacters(in: .whitespaces)
                    let merged = last.error.map { $0 + "\n" + detail } ?? detail
                    last = HermesCronRun(id: last.id, status: last.status, jobID: last.jobID,
                                         source: last.source, claimedAt: last.claimedAt, error: merged)
                    runs.append(last)
                }
                continue
            }

            if line.lowercased().hasPrefix("no cron execution attempts") { continue }

            // Row grammar: id, status, job=…, source=…, claimed_at —
            // located by the tagged tokens so extra padding never matters.
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 5,
                  let jobIdx = tokens.firstIndex(where: { $0.hasPrefix("job=") }),
                  let sourceIdx = tokens.firstIndex(where: { $0.hasPrefix("source=") }),
                  jobIdx >= 2, sourceIdx > jobIdx, sourceIdx + 1 < tokens.count else {
                continue
            }
            runs.append(HermesCronRun(
                id: tokens[0],
                status: tokens[1],
                jobID: String(tokens[jobIdx].dropFirst("job=".count)),
                source: String(tokens[sourceIdx].dropFirst("source=".count)),
                claimedAt: tokens[(sourceIdx + 1)...].joined(separator: " "),
                error: nil
            ))
        }
        return runs
    }
}
