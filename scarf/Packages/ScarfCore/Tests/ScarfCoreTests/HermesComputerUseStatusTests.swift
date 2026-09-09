import Testing
@testable import ScarfCore

/// Coverage for `HermesComputerUseStatus` — the `hermes computer-use
/// permissions status --json` payload behind the Health pane's Computer
/// Use card.
///
/// Every fixture below was produced by running Hermes's own emitter
/// expression at v2026.9.7 — `computer_use_status`'s literal `out` dict
/// (key order is called "an API payload contract" in its docstring)
/// through `json.dumps(st, indent=2, sort_keys=True)`, which is exactly
/// what `_cu_perms_status` prints.
@Suite("HermesComputerUseStatus")
struct HermesComputerUseStatusTests {

    /// macOS, driver installed, Accessibility granted and Screen Recording
    /// NOT granted — so `ready` is false and one doctor probe warns.
    private static let macFixture = """
    {
      "accessibility": true,
      "can_grant": true,
      "checks": [
        {
          "label": "Screenshot probe",
          "message": "capture returned an empty image",
          "status": "warn"
        }
      ],
      "error": null,
      "installed": true,
      "platform": "darwin",
      "platform_supported": true,
      "ready": false,
      "screen_recording": false,
      "screen_recording_capturable": false,
      "source": {
        "accessibility": "TCC"
      },
      "version": "cua-driver 0.4.2"
    }
    """

    /// A remote Linux host: no TCC model at all, readiness is driver health,
    /// and every permission boolean is `null`.
    private static let linuxFixture = """
    {
      "accessibility": null,
      "can_grant": false,
      "checks": [],
      "error": null,
      "installed": true,
      "platform": "linux",
      "platform_supported": true,
      "ready": true,
      "screen_recording": null,
      "screen_recording_capturable": null,
      "source": null,
      "version": "cua-driver 0.4.2"
    }
    """

    /// The early-return branch: no binary, so everything below `installed`
    /// is unknown.
    private static let notInstalledFixture = """
    {
      "accessibility": null,
      "can_grant": true,
      "checks": [],
      "error": null,
      "installed": false,
      "platform": "darwin",
      "platform_supported": true,
      "ready": null,
      "screen_recording": null,
      "screen_recording_capturable": null,
      "source": null,
      "version": null
    }
    """

    @Test func parsesMacPermissionState() {
        let status = HermesComputerUseStatus.parse(Self.macFixture)
        #expect(status?.platform == "darwin")
        #expect(status?.hasTCCPermissions == true)
        #expect(status?.installed == true)
        #expect(status?.version == "cua-driver 0.4.2")
        #expect(status?.accessibility == true)
        #expect(status?.screenRecording == false)
        #expect(status?.ready == false)
        #expect(status?.checks.count == 1)
        #expect(status?.checks.first?.isProblem == true)
        #expect(status?.checks.first?.label == "Screenshot probe")
    }

    /// The booleans are TRI-STATE. `null` means "we couldn't ask", not
    /// "denied" — a card that renders nil as ❌ tells the user to grant a
    /// permission that has no meaning on their host.
    @Test func nullPermissionsStayUnknownNotDenied() {
        let linux = HermesComputerUseStatus.parse(Self.linuxFixture)
        #expect(linux?.accessibility == nil)
        #expect(linux?.screenRecording == nil)
        #expect(linux?.hasTCCPermissions == false)
        // Off macOS, `ready` is driver health.
        #expect(linux?.ready == true)

        let missing = HermesComputerUseStatus.parse(Self.notInstalledFixture)
        #expect(missing?.installed == false)
        #expect(missing?.ready == nil)
        #expect(missing?.version == nil)
        #expect(missing?.hasTCCPermissions == true)  // macOS, just no driver
    }

    /// Nil when there is no payload — an older host, an argparse failure, a
    /// dropped SSH round-trip — so the card hides instead of claiming "not
    /// installed" about a host it never reached.
    @Test func returnsNilWithoutAPayload() {
        #expect(HermesComputerUseStatus.parse("") == nil)
        #expect(HermesComputerUseStatus.parse("cua-driver: not installed") == nil)
        // Right-shaped JSON, wrong payload: no `platform`.
        #expect(HermesComputerUseStatus.parse("{\"ready\": true}") == nil)
    }

    /// Exit 1 just means "not ready", so the payload can arrive next to
    /// other output and must still be found.
    @Test func parsesPayloadAfterLeadingNoise() {
        let noisy = "note: using HERMES_CUA_DRIVER_CMD override\n" + Self.macFixture
        #expect(HermesComputerUseStatus.parse(noisy)?.accessibility == true)
    }

    /// M6 — `status` is cua-driver's vocabulary, folded through Hermes
    /// verbatim. "Not ok" is not "failing": a probe reporting `skipped`,
    /// `n/a` or a spelling a later driver invents used to be painted as a
    /// red error, telling the user something is broken when nothing is.
    @Test(arguments: [
        ("ok", HermesComputerUseCheck.Severity.ok),
        ("OK", .ok),
        ("pass", .ok),
        ("", .ok),
        ("fail", .failure),
        ("error", .failure),
        ("warn", .warning),
        ("degraded", .warning),
        ("skipped", .unknown),
        ("n/a", .unknown),
        ("quantum-unavailable", .unknown),
    ])
    func probeSeverityOnlyReadsKnownFailureSpellingsAsFaults(
        _ pair: (String, HermesComputerUseCheck.Severity)
    ) {
        let check = HermesComputerUseCheck(label: "Screenshot probe", status: pair.0, message: "")
        #expect(check.severity == pair.1, "status: \(pair.0)")
        #expect(check.isProblem == (pair.1 != .ok))
    }
}
