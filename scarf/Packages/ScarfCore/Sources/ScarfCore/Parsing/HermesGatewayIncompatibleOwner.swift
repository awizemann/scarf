import Foundation

/// Reads the v0.22.1 / v0.22.3+ "running but incompatible" answer out of
/// `hermes gateway status`.
///
/// When the gateway answering for this home was started by another Hermes
/// version and this one's clients refuse it, `report_incompatible_owner`
/// (`hermes_cli/gateway_status_notes.py:20-31` @ v0.22.5) prints
///
/// ```
/// ✗ Gateway is running (PID: 4242) but cannot serve this Hermes (incompatible: <reason>)
///   It was started by another Hermes version; TUI, Desktop and chat cannot attach to it.
///   Replace it with this version:
///     hermes gateway restart
/// ```
///
/// The `Gateway is running (PID: …)` spelling comes from `_cmd_status`'s
/// no-service branch, IN PLACE OF the `✓ … (Running manually …)` pair
/// (`hermes_cli/gateway.py:5617-5619`); a service-managed gateway gets
/// `The running gateway` instead, after the service's own status
/// (`:5613`). `<reason>` is `observed.reason_code or 'unknown'` (`:17`).
/// Gated on ``HermesCapabilities/hasGatewayIncompatibleOwnerStatus`` by the
/// caller; the module is absent at v0.22.0 and v0.22.2.
public enum HermesGatewayIncompatibleOwner {

    static let clause = " but cannot serve this Hermes (incompatible: "
    static let handRunSubject = "Gateway is running (PID: "
    static let serviceSubject = "The running gateway"

    /// `<reason>` when `statusOutput` carries the incompatible-owner line,
    /// else `nil`.
    public static func reason(statusOutput: String) -> String? {
        line(statusOutput: statusOutput).map(\.reason)
    }

    /// True when the incompatible gateway is the no-service branch's — a
    /// gateway run by hand, which the restart guard treats like
    /// `(Running manually, not as a system service)`.
    public static func isHandRun(statusOutput: String) -> Bool {
        line(statusOutput: statusOutput)?.handRun == true
    }

    private static func line(statusOutput: String) -> (reason: String, handRun: Bool)? {
        for line in HermesCLIVerdict.significantLines(statusOutput) {
            let head = HermesCLIVerdict.unglyphed(line)
            let handRun = head.hasPrefix(handRunSubject)
            guard handRun || head.hasPrefix(serviceSubject), head.hasSuffix(")"),
                  let range = head.range(of: clause) else { continue }
            let reason = head[range.upperBound...].dropLast()
            guard !reason.isEmpty else { continue }
            return (String(reason), handRun)
        }
        return nil
    }
}
