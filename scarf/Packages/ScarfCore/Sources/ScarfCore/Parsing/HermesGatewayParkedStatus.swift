import Foundation

/// Reads the v0.21.5 "parked profile" answer out of `hermes gateway status`.
///
/// A named profile the host multiplexer serves can be PARKED: `gateway stop`
/// on it touches `<HERMES_HOME>/gateway.parked` and asks the host to drop it
/// (`hermes_cli/gateway_profile_lifecycle.py:57-67` @ `v2026.9.24`;
/// `parked_marker_path`, `hermes_cli/profiles.py:1038-1039`). `gateway
/// status` on that profile then early-returns after ONE line —
///
/// ```
/// Profile 'work': parked (hermes -p work gateway start)
/// ```
///
/// — from `print_parked_status` (`gateway_profile_lifecycle.py:82-88`,
/// hooked at `hermes_cli/gateway.py:5021-5023`). There is no `✓`/`✗`
/// verdict, so a reader that only knows those falls back to the profile's
/// `gateway_state.json`, which is whatever the last run wrote.
///
/// **The default profile prints the same line shape and keeps going.** On
/// the default profile `print_parked_status` lists every parked satellite
/// (`:89-97`) and returns False, so the normal status output follows. A
/// parked line is therefore only THIS profile's verdict when it is the whole
/// output: exactly one significant line, and it is a parked line. Anything
/// else — including stray stderr noise beside it — answers `nil`, which is
/// the pre-v0.21.5 reading (the caller's ✓/✗/state fallback), never a guess.
public enum HermesGatewayParkedStatus {

    /// The parked profile's name when `statusOutput` is the named-profile
    /// early return, else `nil`. The name must appear identically in both
    /// places the line prints it (`Profile '{name}'` and `hermes -p {name}`),
    /// which is what `print_parked_status`'s f-string guarantees.
    public static func parkedProfile(statusOutput: String) -> String? {
        let lines = HermesCLIVerdict.significantLines(statusOutput)
        guard lines.count == 1, let line = lines.first else { return nil }
        let prefix = "Profile '"
        let middle = "': parked (hermes -p "
        let suffix = " gateway start)"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let nameStart = line.index(line.startIndex, offsetBy: prefix.count)
        let suffixStart = line.index(line.endIndex, offsetBy: -suffix.count)
        // Search only between the prefix and the suffix, so a short line
        // whose pieces overlap can never produce an inverted range.
        guard nameStart <= suffixStart,
              let mid = line.range(of: middle, range: nameStart..<suffixStart) else { return nil }
        let name = String(line[nameStart..<mid.lowerBound])
        let echoed = String(line[mid.upperBound..<suffixStart])
        guard !name.isEmpty, name == echoed else { return nil }
        return name
    }
}
