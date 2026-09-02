import Foundation

/// One dynamic webhook subscription from `hermes webhook list`.
public struct HermesWebhookEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let deliver: String
    public let events: [String]
    /// Full URL as the CLI printed it (`<base>/webhooks/<name>`).
    public let url: String
    /// Filter/transform script under `~/.hermes/scripts/`, when set.
    public let script: String
    /// True when the route was created with `--deliver-only` — the CLI
    /// appends `(direct — no agent)` to the deliver target.
    public let deliverOnly: Bool

    public init(name: String, description: String, deliver: String, events: [String], url: String, script: String, deliverOnly: Bool) {
        self.name = name
        self.description = description
        self.deliver = deliver
        self.events = events
        self.url = url
        self.script = script
        self.deliverOnly = deliverOnly
    }
}

/// Parser for `hermes webhook list`.
///
/// Rewritten against the real emitter (`hermes_cli/webhook.py::_cmd_list`,
/// verified at v2026.8.31). **Every** line it prints is indented:
///
/// ```
///
///   2 webhook subscription(s):
///
///   ◆ deploys
///     Notify on deploy events
///     URL:     http://localhost:8787/webhooks/deploys
///     Events:  push, release
///     Deliver: slack
///     Script:  filter.py
///
///   ◆ alerts
///     URL:     http://localhost:8787/webhooks/alerts
///     Events:  (all)
///     Deliver: log (direct — no agent)
///
/// ```
///
/// The previous parser opened a new record only on a line with **no**
/// leading whitespace, which this format never produces — so it matched
/// nothing and the Webhooks section rendered permanently empty even with
/// subscriptions configured. Records are keyed on the `◆ ` bullet, and
/// the bare line directly under a bullet is the optional description
/// (there is no `Description:` label — the CLI prints `desc` alone).
///
/// The CLI has no `--json` flag for `webhook list` (the `list` subparser
/// takes no arguments at all), so text parsing is the only contract.
public enum HermesWebhookList {

    /// The bullet the CLI prints before each subscription name.
    private static let bullet = "◆"

    /// Empty-state sentinel — matched as a whole trimmed line so a
    /// subscription whose *description* mentions the phrase cannot fake
    /// an empty board.
    public static func isEmptyListing(_ output: String) -> Bool {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("No dynamic webhook subscriptions.")
    }

    public static func parse(_ output: String) -> [HermesWebhookEntry] {
        var results: [HermesWebhookEntry] = []

        var name = ""
        var description = ""
        var deliver = ""
        var deliverOnly = false
        var events: [String] = []
        var url = ""
        var script = ""
        /// Set right after a bullet: the next unlabelled line (if any) is
        /// this route's description.
        var expectingDescription = false

        func flush() {
            guard !name.isEmpty else { return }
            results.append(HermesWebhookEntry(
                name: name,
                description: description,
                deliver: deliver,
                events: events,
                url: url,
                script: script,
                deliverOnly: deliverOnly
            ))
            name = ""; description = ""; deliver = ""; deliverOnly = false
            events = []; url = ""; script = ""
        }

        for raw in output.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix(bullet) {
                flush()
                name = String(trimmed.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
                expectingDescription = true
                continue
            }
            guard !name.isEmpty else { continue }   // header/preamble lines

            if let value = value(of: "URL:", in: trimmed) {
                url = value
                expectingDescription = false
            } else if let value = value(of: "Events:", in: trimmed) {
                // `(all)` is the CLI's placeholder for "no filter", not an
                // event named "(all)".
                events = value == "(all)"
                    ? []
                    : value.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                expectingDescription = false
            } else if let value = value(of: "Deliver:", in: trimmed) {
                let marker = "(direct"
                if let range = value.range(of: marker) {
                    deliverOnly = true
                    deliver = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                } else {
                    deliver = value
                }
                expectingDescription = false
            } else if let value = value(of: "Script:", in: trimmed) {
                script = value
                expectingDescription = false
            } else if expectingDescription {
                description = trimmed
                expectingDescription = false
            }
        }
        flush()
        return results
    }

    /// Case-insensitive `Label: value` split that keeps colons inside the
    /// value (URLs contain `://` and a port colon).
    private static func value(of label: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(label.lowercased()) else { return nil }
        return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
}
