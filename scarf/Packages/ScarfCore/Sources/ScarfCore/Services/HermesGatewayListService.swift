import Foundation

/// Cross-profile snapshot derived from `hermes gateway list` (Hermes v0.16).
/// Each profile is one configured Messaging Gateway instance — most users
/// have a single `default` profile, but power users keep separate profiles
/// for work / personal / project-specific accounts.
public struct GatewayListSnapshot: Sendable, Equatable {
    public struct ProfileEntry: Sendable, Equatable {
        public let profile: String
        public let isRunning: Bool
        public let pid: Int?
        /// v0.21.1: the profile is running because the DEFAULT profile's
        /// multiplexer is carrying its inbound traffic, not because it has a
        /// gateway process of its own. `_gateway_list` prints
        /// `— served by the default multiplexer` in the slot where a
        /// self-hosted profile prints `— PID <n>`
        /// (`hermes_cli/gateway.py:1520-1522` at tag `v2026.9.7`), so
        /// `isRunning` is true and `pid` is nil. Always `false` on a
        /// pre-v0.21.1 host, which never emits the clause.
        public let servedByMultiplexer: Bool

        public init(
            profile: String,
            isRunning: Bool,
            pid: Int?,
            servedByMultiplexer: Bool = false
        ) {
            self.profile = profile
            self.isRunning = isRunning
            self.pid = pid
            self.servedByMultiplexer = servedByMultiplexer
        }
    }
    public let profiles: [ProfileEntry]
    public let detectedAt: Date

    public init(profiles: [ProfileEntry], detectedAt: Date = Date()) {
        self.profiles = profiles
        self.detectedAt = detectedAt
    }

    /// One-line digest for the Messaging Gateway page header. Format depends
    /// on shape:
    /// - 0 profiles: `"no profiles configured"`
    /// - 1 profile, running: `"default profile · running"`
    /// - 1 profile, stopped: `"default profile · stopped"`
    /// - 1 profile, multiplexed (v0.21.1+):
    ///   `"work profile · served by the default multiplexer"`
    /// - >1 profile: `"3 profiles (2 running)"`
    ///
    /// There is no per-profile platform clause: `hermes gateway list` prints
    /// a text table with no platform column and no `--json` alternative, so
    /// the parser has nothing to fill one from. The clauses that used to be
    /// here were guarded on a list the only producer always built empty —
    /// dead in every run, and a standing invitation to "fix" the digest by
    /// inventing platform data Hermes never gave us.
    public var headerDigest: String {
        if profiles.isEmpty { return "no profiles configured" }

        if profiles.count == 1 {
            let p = profiles[0]
            let state: String
            if p.servedByMultiplexer {
                state = "served by the default multiplexer"
            } else {
                state = p.isRunning ? "running" : "stopped"
            }
            return "\(p.profile) profile · \(state)"
        }

        let runningCount = profiles.filter(\.isRunning).count
        return "\(profiles.count) profiles (\(runningCount) running)"
    }
}

/// Pure parser + sync fetcher for `hermes gateway list` (Hermes v0.16).
/// `hermes gateway list` has no `--json` flag — it prints a text table — so
/// the parser reads that text directly. The fetcher returns `nil` on a
/// non-zero exit (host without the subcommand) so the digest row hides
/// itself.
///
/// Expected text shape:
/// ```
/// Gateways:
///   ✓ default (current)        — PID 44417
///   ✓ work                     — served by the default multiplexer
///   ✗ scarfbox-smoke           — not running
///   ✗ scarfbox-test            — not running
/// ```
/// `✓`/`✗` gives `isRunning`; the word after it is the profile name (a
/// trailing `(current)` marker is stripped); `— PID <n>` (em dash, U+2014)
/// carries the pid on running lines. Text output has no per-profile platform
/// list, and there is no `--json` form to get one from, so the snapshot
/// carries none.
///
/// **v0.21.1 third clause.** `_gateway_list` (`hermes_cli/gateway.py:1514-1525`
/// at tag `v2026.9.7`) prints `served by the default multiplexer` in the
/// trailing slot for a running profile whose own `gateway.pid` yields no pid
/// but which `named_profile_served_by_running_multiplexer()` reports as
/// multiplexed. Recognised EXPLICITLY (`servedByMultiplexer = true`, `pid`
/// nil) rather than falling through the pid parse, so the state is
/// distinguishable from "running, pid unreadable". Absent at v2026.8.31.
///
/// The detection is **synchronous** — run from a `Task.detached` to avoid
/// blocking MainActor on remote SSH round-trips. The pure `parse(_:)`
/// helper has no I/O and can be used in tests against canned text.
public enum HermesGatewayListService {

    /// Parse the text table from `hermes gateway list` into a snapshot.
    /// Skips the `Gateways:` header; each subsequent profile line yields a
    /// `ProfileEntry`. Returns `nil` for empty / whitespace-only input.
    public static func parse(_ text: String) -> GatewayListSnapshot? {
        let trimmedWhole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWhole.isEmpty else { return nil }

        var entries: [GatewayListSnapshot.ProfileEntry] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Skip the `Gateways:` header (and any other non-profile line
            // that lacks a running marker).
            guard line.hasPrefix("✓") || line.hasPrefix("✗") else { continue }

            let isRunning = line.hasPrefix("✓")

            // Strip the marker, then split off the trailing `— …` clause
            // (em dash, U+2014) which carries pid / status.
            var rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            var pid: Int?
            var served = false
            if let dashRange = rest.range(of: "—") {
                let after = rest[dashRange.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                rest = String(rest[..<dashRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                // Running lines read `PID <n>` or (v0.21.1) `served by the
                // default multiplexer`; stopped lines `not running`.
                if after.hasPrefix("PID") {
                    let digits = after.drop(while: { !$0.isNumber })
                    pid = Int(digits.prefix(while: { $0.isNumber }))
                } else if after.hasPrefix("served by the default multiplexer") {
                    served = true
                }
            }

            // The profile name is the first whitespace-delimited token; a
            // trailing `(current)` marker is a separate token, so dropping
            // everything after the first space removes it.
            let profile = rest
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first
                .map(String.init) ?? ""
            guard !profile.isEmpty else { continue }

            entries.append(GatewayListSnapshot.ProfileEntry(
                profile: profile,
                isRunning: isRunning,
                pid: pid,
                servedByMultiplexer: served
            ))
        }

        // No recognizable profile lines (e.g. garbage input) → nil.
        guard !entries.isEmpty else { return nil }
        return GatewayListSnapshot(profiles: entries)
    }

    /// Cap on the `gateway list` spawn. Named, not inherited: a wedged SSH
    /// host must not pin a gateway load (charter C10).
    public static let fetchTimeout: TimeInterval = 10

    /// Synchronous fetch helper — call from a `Task.detached`. Returns
    /// `nil` when the subcommand fails (host without `gateway list`) or when
    /// the output has no recognizable profile lines.
    ///
    /// - Parameter runner: test seam only (the Mac target's `HermesCLIRunner`
    ///   shape). Production passes `nil` and keeps the transport call below,
    ///   because that captures stdout ALONE: `runHermes`-style combined
    ///   output would let a stderr line with a profile row's shape parse as a
    ///   phantom profile. Its `output` is therefore read as stdout. Without
    ///   this parameter this third probe of a gateway load was the one spawn
    ///   no test could observe.
    public static func fetch(
        context: ServerContext,
        runner: (@Sendable (_ args: [String], _ timeout: TimeInterval) -> (output: String, exitCode: Int32))? = nil
    ) -> GatewayListSnapshot? {
        if let runner {
            let result = runner(["gateway", "list"], fetchTimeout)
            guard result.exitCode == 0 else { return nil }
            return parse(result.output)
        }
        let transport = context.makeTransport()
        let executable = context.paths.hermesBinary
        do {
            let result = try transport.runProcess(
                executable: executable,
                args: ["gateway", "list"],
                stdin: nil,
                timeout: fetchTimeout
            )
            guard result.exitCode == 0 else { return nil }
            return parse(result.stdoutString)
        } catch {
            return nil
        }
    }
}
