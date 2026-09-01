import Foundation

/// One durable cron failure incident from `hermes cron incidents`
/// (Hermes v0.20.6+; callers gate on `HermesCapabilities.hasCronIncidents`).
///
/// Incidents group *failed* executions by `(job_id, normalized error
/// signature)` so the same job failing the same way stops re-pinging the
/// operator once acknowledged (`cron/incidents.py`). Lifecycle:
/// `detected` → `alerted` → `closed`; acking closes one, and it stays
/// closed until the error text changes (which mints a new incident id).
public struct HermesCronIncident: Sendable, Equatable, Identifiable {
    public let id: String
    /// `detected` / `alerted` / `closed` — or whatever a future Hermes
    /// prints. `INCIDENT_STATES` is deliberately Python-side only (no
    /// SQLite CHECK), so new states can appear; the parser never validates.
    public let state: String
    public let jobID: String
    /// `rate_limit` / `timeout` / `auth` / `delivery` / `config` /
    /// `script` / `agent` / `unknown`.
    public let failureType: String
    public let firstSeenAt: String
    public let lastSeenAt: String
    /// Already redacted + whitespace-collapsed + truncated to ~160 chars
    /// by the CLI at print time — safe to render verbatim.
    public let error: String
    public let outputFile: String?

    public init(
        id: String,
        state: String,
        jobID: String,
        failureType: String,
        firstSeenAt: String,
        lastSeenAt: String,
        error: String,
        outputFile: String?
    ) {
        self.id = id
        self.state = state
        self.jobID = jobID
        self.failureType = failureType
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.error = error
        self.outputFile = outputFile
    }

    /// Only an open incident is worth acking.
    public var isOpen: Bool { state != "closed" }
}

/// Argv builder + text parser for `hermes cron incidents [--state s]`
/// and `hermes cron incidents ack <id>`.
///
/// There is no `--json` flag (verified against v0.21.0
/// `hermes_cli/subcommands/cron.py:287-305`), so we parse the block
/// format `hermes_cli/cron.py::cron_incidents` prints:
///
/// ```
///   <incident_id>  <state>
///     Job:        <job_id>
///     Type:       <failure_type>
///     First seen: <iso>
///     Last seen:  <iso>
///     Error:      <one-line error>
///     Output:     <path>            ← optional
/// ```
///
/// preceded by a box-drawn "Cron Failure Incidents" banner and followed
/// by a `N incident(s) | ack one with: …` footer, plus the empty
/// sentinel `No cron failure incidents recorded.`.
public enum HermesCronIncidentsParser {

    // MARK: - Argv builders

    /// `["cron", "incidents"]` (+ `--state <s>` when filtering).
    /// `state` is validated against the CLI's argparse `choices` — an
    /// unknown value would make argparse reject the whole invocation,
    /// so it is dropped rather than forwarded.
    public static func listArgs(state: String? = nil) -> [String] {
        var args = ["cron", "incidents"]
        if let state, ["detected", "alerted", "closed"].contains(state) {
            args += ["--state", state]
        }
        return args
    }

    /// `["cron", "incidents", "ack", "<id>"]`.
    public static func ackArgs(incidentID: String) -> [String] {
        ["cron", "incidents", "ack", incidentID]
    }

    // MARK: - Parser

    /// Parse the block listing. Blank output and the empty sentinel fold
    /// to `[]`. A malformed block is dropped rather than aborting the
    /// parse — one weird incident shouldn't blank the whole section.
    public static func parse(text: String) -> [HermesCronIncident] {
        var incidents: [HermesCronIncident] = []
        var header: (id: String, state: String)?
        var fields: [String: String] = [:]

        func flush() {
            defer { header = nil; fields = [:] }
            guard let header, let jobID = fields["Job"], !jobID.isEmpty else { return }
            incidents.append(HermesCronIncident(
                id: header.id,
                state: header.state,
                jobID: jobID,
                failureType: fields["Type"] ?? "unknown",
                firstSeenAt: fields["First seen"] ?? "",
                lastSeenAt: fields["Last seen"] ?? "",
                error: fields["Error"] ?? "",
                outputFile: fields["Output"].flatMap { $0.isEmpty ? nil : $0 }
            ))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Hermes suppresses ANSI when stdout isn't a tty (which is
            // always, for Scarf's piped runs) — strip anyway so a
            // `FORCE_COLOR`-style future or a tty-allocating transport
            // can't break the field match.
            let line = stripANSI(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Banner / footer / sentinel chrome.
            if trimmed.hasPrefix("┌") || trimmed.hasPrefix("│") || trimmed.hasPrefix("└") { continue }
            if trimmed.lowercased().hasPrefix("no cron failure incidents") { continue }
            if trimmed.lowercased().hasPrefix("(filtered by state") { continue }
            if trimmed.contains("ack one with:") { continue }

            // Detail lines are indented 4; header lines indented 2. Match
            // on the label rather than the exact indent so padding drift
            // in a future release doesn't silently drop fields.
            if let colon = trimmed.firstIndex(of: ":"), header != nil {
                let label = String(trimmed[trimmed.startIndex..<colon])
                if detailLabels.contains(label) {
                    fields[label] = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
            }

            // Header: `<id>  <state>`.
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { continue }
            flush()
            header = (id: tokens[0], state: tokens[1])
        }
        flush()
        return incidents
    }

    private static let detailLabels: Set<String> =
        ["Job", "Type", "First seen", "Last seen", "Error", "Output"]

    /// Minimal CSI/SGR stripper — enough for `hermes_cli/colors.py`.
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = ""
        var iterator = s.makeIterator()
        var pending: Character?
        while let ch = pending ?? iterator.next() {
            pending = nil
            guard ch == "\u{1B}" else { out.append(ch); continue }
            guard let next = iterator.next() else { break }
            guard next == "[" else { pending = next; continue }
            // Consume until the final byte (@ … ~).
            while let c = iterator.next() {
                if let a = c.asciiValue, a >= 0x40, a <= 0x7E { break }
            }
        }
        return out
    }
}
