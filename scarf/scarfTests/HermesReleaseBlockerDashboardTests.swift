import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Release blocker 3 — the Health pane's **Web Dashboard** row was gated on
/// `!context.isRemote` ALONE, with no capability flag (charter C1), and the
/// daemon it starts had no ceiling on the way out (C10).
///
/// **The tag walk, re-opened.** `hermes dashboard` does not exist on Scarf's
/// supported minimum: the string `dashboard` occurs ZERO times in
/// `hermes_cli/main.py` at `v2026.3.30` (= Hermes 0.6.0) and zero times at
/// `v2026.4.8` (0.8.0, the tag before the floor). `def cmd_dashboard(args)`
/// first appears at `hermes_cli/main.py:4458` of `v2026.4.13`
/// (`pyproject.toml` = `0.9.0`), registered in the verb list at `:4180` and
/// `:5978`; it is still there at `v2026.9.7` (`:2502`). So on 0.6.0–0.8.x the
/// row spawned a verb argparse does not know — which Hermes routes to the
/// AGENT (C5), so the spawn "succeeded", nothing bound the port, and the
/// HTTP probe simply timed out into a Start button that never went green.
///
/// **C1 for an ADDED gate.** Every range outside the window: 0.9.0 and later
/// render byte-identically to the previous release (the flag is true there),
/// and an undetected host hides the row until detection lands — the same
/// shape the other four gated Health rows use, with `HealthView`'s
/// `.onChange(of: capabilitiesStore?.capabilities.detected)` re-rendering
/// when it does. The only behaviour that changes is on the range where the
/// control could never have worked.
@Suite("Web Dashboard row is capability-gated and its daemon is bounded")
struct WebDashboardGateTests {

    private static func caps(_ major: Int, _ minor: Int, _ patch: Int) -> HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes \(major).\(minor).\(patch)",
            semver: HermesCapabilities.SemVer(major: major, minor: minor, patch: patch),
            dateVersion: nil
        )
    }

    // MARK: - The flag, at and around its floor

    @Test("the row's gate is false on a 0.8 host and true on a 0.9 host")
    func flagAtItsFloor() {
        #expect(!Self.caps(0, 6, 0).hasDashboardCommand, "0.6.0 is the supported minimum and has no `dashboard` verb")
        #expect(!Self.caps(0, 8, 0).hasDashboardCommand, "v2026.4.8 — `dashboard` occurs zero times in main.py")
        #expect(Self.caps(0, 9, 0).hasDashboardCommand, "v2026.4.13 — `def cmd_dashboard` at main.py:4458")
        #expect(Self.caps(0, 9, 1).hasDashboardCommand, "a patch above the floor is still on")
        #expect(Self.caps(0, 21, 1).hasDashboardCommand, "still present at v2026.9.7, main.py:2502")
        #expect(!HermesCapabilities.empty.hasDashboardCommand,
                "an undetected host hides the row until detection lands")
    }

    // MARK: - The view actually consults it

    /// A flag with no consumer gates nothing — `hasDashboardCommand` had zero
    /// production consumers for five rounds. This pins that the row's `if` in
    /// `HealthView` names it, brace-free and by repo-relative path.
    @Test("HealthView gates webDashboardRow on hasDashboardCommand as well as isRemote")
    func viewConsultsTheFlag() throws {
        let source = try Self.source(at: "scarf/scarf/Features/Health/Views/HealthView.swift")
        let lines = source.components(separatedBy: "\n")
        let rowIndex = try #require(
            lines.firstIndex { $0.contains("webDashboardRow") && !$0.contains("private var") },
            "the row is no longer rendered — has it moved?"
        )
        // Walk back to the `if` that guards it (the row sits inside a short
        // `if … { Divider(); webDashboardRow }`).
        let window = lines[max(0, rowIndex - 6)..<rowIndex].joined(separator: "\n")
        #expect(window.contains("hasDashboardCommand"), """
            The Web Dashboard row is rendered without consulting \
            `hasDashboardCommand`. On a pre-0.9 host `hermes dashboard` is an \
            unknown verb that Hermes routes to the agent, so Start silently \
            does nothing. Guard window was:
            \(window)
            """)
        #expect(window.contains("isRemote"), "the pre-existing remote guard must survive: \(window)")
    }

    // MARK: - The daemon has a stop ceiling

    @Test("the dashboard's stop ceiling is a real, short budget")
    func stopCeilingIsReal() {
        #expect(HealthViewModel.dashboardStopCeiling > 0,
                "a ceiling of zero is no ceiling — SIGTERM would escalate instantly")
        #expect(HealthViewModel.dashboardStopCeiling <= 5,
                "the row settles and re-probes after 1.2 s; a long ceiling only lets the status line lie")
        #expect(HealthViewModel.dashboardStopCeiling == HermesProxyService.stopCeiling,
                "same shape of child (an HTTP server with nothing to flush), same budget")
    }

    /// The escalation itself: SIGTERM, then the bounded
    /// `waitUntilExit(timeout:)` (poll → pid-guarded SIGKILL → poll). A bare
    /// `terminate()` is the defect — it is what the Stop button used to do,
    /// and a uvicorn that ignores SIGTERM held the port against the next
    /// Start while the button reported success.
    @Test("stopDashboard escalates SIGTERM with a bounded wait")
    func stopPathEscalates() throws {
        let source = try Self.source(at: "scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift")
        let body = try #require(Self.functionBody(named: "func stopDashboard()", in: source),
                                "stopDashboard is gone — has the row moved?")
        #expect(body.contains("terminate()"), "SIGTERM is still asked first, before the ceiling")
        #expect(body.contains("waitUntilExit(timeout:"), """
            The owned dashboard process is signalled with no escalation and no \
            ceiling — the exact shape round-5 P48 fixed in \
            `HermesProxyService.stop()`. Body was:
            \(body)
            """)
        #expect(body.contains("Thread.detachNewThread"), """
            The poll loop is `Thread.sleep`-based, so it must not run on the \
            cooperative pool. Body was:
            \(body)
            """)
    }

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(at relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Brace-matched body of the declaration whose line contains `decl`.
    static func functionBody(named decl: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(decl) }) else { return nil }
        var depth = 0
        var started = false
        var body: [String] = []
        for line in lines[start...] {
            for c in line {
                if c == "{" { depth += 1; started = true }
                if c == "}" { depth -= 1 }
            }
            body.append(line)
            if started && depth == 0 { break }
        }
        return body.joined(separator: "\n")
    }
}
