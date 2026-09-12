import Foundation
import ScarfCore

/// The banner wording for a gateway control action, including the arm that
/// the four call sites were missing: ``HermesCLIOutcome/Confidence/unconfirmed``.
///
/// ## Why a third arm exists at all
///
/// P40b split "it refused" from "it printed nothing I recognise"
/// (``HermesCLIOutcome/Confidence``) precisely because silence is one of the
/// answers Hermes gives: the s6 dispatch prints nothing on its success path
/// (`hermes_cli/gateway.py:5608-5629` @ v2026.9.7), and `_cmd_restart`'s
/// no-service arm prints `Starting gateway...` and then runs the gateway in
/// the FOREGROUND (`:6062-6066`), which ends at Scarf's own timeout. Every
/// banner then branched on the BOOL again — `guard outcome.succeeded` — so
/// both shapes were laundered straight back into "Gateway stop failed" on
/// screen while the gateway was, in fact, doing what the user asked.
///
/// The neutral arm says what is true, keeps `actionFailed` false (a
/// could-not-confirm is not a red banner), and leans on the settle-reload
/// that every one of these call sites already schedules: the status is the
/// authority, not the verdict.
enum GatewayActionBanner {

    /// The neutral message for a `.unconfirmed` outcome. `detail` carries the
    /// verdict's own note when it has one — the live case is
    /// ``ScarfCore/HermesGatewayServiceVerdict/foregroundStartNote``.
    static func unconfirmed(_ verb: HermesGatewayServiceVerdict.Verb, detail: String?) -> String {
        let stem: String = switch verb {
        case .start:
            String(localized: "Start sent; Scarf could not confirm it from the output — the status will update")
        case .stop:
            String(localized: "Stop sent; Scarf could not confirm it from the output — the status will update")
        case .restart:
            String(localized: "Restart sent; Scarf could not confirm it from the output — the status will update")
        }
        return detail.map { "\(stem) — \($0)" } ?? stem
    }
}
