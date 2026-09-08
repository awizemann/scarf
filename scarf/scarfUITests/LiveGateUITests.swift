//
//  LiveGateUITests.swift
//  scarfUITests
//
//  Proves the Live test plan's wiring works, so the first real Live
//  journey doesn't have to debug the plan and the journey at once.
//
//  Under Smoke and Full this SKIPS (no `SCARF_UITEST_LIVE`); under
//  `-testPlan Live` it runs and asserts the env var actually reached the
//  runner process. A silently-broken Live plan would otherwise look
//  identical to "all Live tests skipped", which is exactly the failure
//  mode a release gate must not have.
//
//  Template for a real Live journey:
//
//      final class MyLiveJourneyUITests: ScarfUITestCase {
//          @MainActor func testSomething() throws {
//              try requireLive()          // FIRST — before any launch
//              let app = makeApp()
//              launchAndSurface(app)
//              defer { gracefulQuit(app) }
//              …
//          }
//      }
//
//  New journeys need no test-plan edits: Full and Live both take the
//  whole `scarfUITests` target, and `requireLive()` is what separates them.
//

import XCTest

final class LiveGateUITests: ScarfUITestCase {

    /// Deliberately does not launch the app — this asserts the PLAN, not a
    /// surface, and staying launch-free keeps it free in the Full run.
    func testLivePlanEnvironmentReachesTheRunner() throws {
        try requireLive()
        let value = ProcessInfo.processInfo.environment[Self.liveEnvVar]
        XCTAssertEqual(
            value, "1",
            "requireLive() let the test through but \(Self.liveEnvVar) is \(value ?? "<unset>") — check Live.xctestplan's environmentVariableEntries."
        )
    }
}
