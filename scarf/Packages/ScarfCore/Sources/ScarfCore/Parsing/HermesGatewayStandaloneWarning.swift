import Foundation

/// Reads the v0.21.5 "this gateway is STANDALONE" box out of `hermes gateway
/// status` (P7e, live finding on Alan's host 2026-09-26).
///
/// The default profile's boot guard (`implicit_multiplex_blocker`,
/// `hermes_cli/gateway_multiplex_mode.py:93-129` @ `v2026.9.24`) can keep the
/// host gateway standalone even though `gateway.multiplex_profiles` is unset
/// or an explicit `false` — both mean "multiplex by default" from v0.21.4
/// (``HermesProfileRoutes/multiplexStatus(capabilities:)``). `gateway status`
/// then prints a boxed warning built by `standalone_warning_lines` /
/// `recorded_standalone_warning_lines` (`gateway_multiplex_mode.py:299-335`)
/// and hooked into `_cmd_status` at `hermes_cli/gateway.py:5051,5059`:
///
/// ```
/// ┌────────────────────────────────────────────────────────────────┐
/// │ ⚠ This gateway is STANDALONE: it serves only its own profile.  │
/// │ Profiles NOT served (their bots stay silent): gateway, scarfbox-test │
/// │ Why: duplicate TELEGRAM_BOT_TOKEN in 'gateway' and 'scarfbox-test' profiles │
/// │ Fix: hermes gateway migrate --multiplex                        │
/// └────────────────────────────────────────────────────────────────┘
/// ```
///
/// **Not the same text as v0.21.4.** At `v2026.9.21` the same guard prints a
/// single unboxed line — `⚠ Serving the default profile only: {reason}`
/// (`hermes_cli/gateway.py:1542-1548` @ that tag) — with no unserved-profile
/// list and no fix command. The audit that raised this item called the box
/// "absent at v2026.9.21"; the more precise finding (P7e re-walk, charter C2)
/// is that v0.21.4 has a DIFFERENT, shorter warning, not none — so this
/// parser is deliberately gated to the box shape only
/// (``HermesCapabilities/hasGatewayStandaloneStatusBox``) and does not read
/// the older one-liner.
///
/// Box borders are drawn to fit the LONGEST line (`_box`,
/// `gateway_multiplex_mode.py:221-225`), so border width varies with the
/// unserved-profile list and the reason text — this parser never assumes a
/// fixed width. It keys on the four labelled lines' own prefixes instead of
/// the border box-drawing characters, so a host whose Rich/terminal width
/// wraps one of the longer lines still recovers the fields that matter (a
/// wrapped `Why:` reason is truncated at the wrap point, same as reading it
/// by eye in a narrow terminal).
public struct HermesGatewayStandaloneWarning: Sendable, Equatable {
    /// Named profiles the standalone gateway leaves without a bot
    /// (`unserved_profiles()`, `gateway_multiplex_mode.py:289-294`).
    public let unservedProfiles: [String]
    /// The boot guard's own reason (`MultiplexDecision.reason` — e.g. a
    /// duplicate bot credential, an s6 host, a profile still running its own
    /// gateway).
    public let reason: String
    /// The literal remedy command (`MIGRATE_COMMAND`,
    /// `hermes_cli/gateway_migrate.py:38`) — shown as copyable text, never a
    /// button: `gateway migrate --multiplex` mutates every profile's
    /// wiring and is not something Scarf should fire from a click (C3/C10
    /// spirit: this is a real topology change, not a read).
    public let fixCommand: String

    private static let headerPrefix = "⚠ This gateway is STANDALONE"
    private static let unservedPrefix = "Profiles NOT served (their bots stay silent): "
    private static let whyPrefix = "Why: "
    private static let fixPrefix = "Fix: "

    /// Strip a box-drawing side border (`│ … │`) if present, else return the
    /// line unchanged — callers pass already box-agnostic content.
    private static func unboxed(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == "│" || first == " " {
            text = text.dropFirst()
        }
        while let last = text.last, last == "│" || last == " " {
            text = text.dropLast()
        }
        return String(text)
    }

    /// Parses `statusOutput` for the box; `nil` when it isn't present (a
    /// healthy multiplexer, a pre-v0.21.5 host, or the older v0.21.4
    /// one-liner — see the type doc).
    public static func parse(statusOutput: String) -> HermesGatewayStandaloneWarning? {
        let lines = HermesCLIVerdict.significantLines(statusOutput).map(unboxed)
        guard lines.contains(where: { $0.hasPrefix(headerPrefix) }) else { return nil }
        var unserved: [String] = []
        var reason = ""
        var fix = ""
        for line in lines {
            if line.hasPrefix(unservedPrefix) {
                unserved = line.dropFirst(unservedPrefix.count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if line.hasPrefix(whyPrefix) {
                reason = String(line.dropFirst(whyPrefix.count))
            } else if line.hasPrefix(fixPrefix) {
                fix = String(line.dropFirst(fixPrefix.count))
            }
        }
        guard !unserved.isEmpty else { return nil }
        return HermesGatewayStandaloneWarning(unservedProfiles: unserved, reason: reason, fixCommand: fix)
    }
}
