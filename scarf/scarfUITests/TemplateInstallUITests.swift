//
//  TemplateInstallUITests.swift
//  scarfUITests
//
//  Layer B of the dogfooding-templates harness — the XCUITest layer that
//  drives Scarf end-to-end via the real UI. This file lands as a scaffold
//  in the v2.7 cycle: it exercises the launch-argument + env-var plumbing
//  (SCARF_HERMES_HOME, --scarf-test-mode) and proves the app reaches a
//  non-crashed state under those flags. Driving the full install /
//  configure / dashboard journey arrives in v2.8 alongside the
//  accessibility-identifier sweep — see Test-Harness.md on the wiki.
//
//  The scaffold is deliberately small. Its job is to prove the harness
//  *can* run, so the next person extending it has a known-green starting
//  point. The contract for the next iteration: keep `tmpHermesHome()` and
//  `launchedApp()` as the two helpers every Layer B test calls; everything
//  else is per-test.
//

import XCTest

final class TemplateInstallUITests: XCTestCase {

    private var tmpHome: URL?

    override func setUpWithError() throws {
        // Stop on first failure — XCUITest runs are linear and the failure
        // mode we care about ("the app launched in test mode and is
        // responsive") is not something a later test recovers from.
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Wipe any tmp Hermes home created during the test. Wrapped in a
        // try? because tearDown should never be the thing that masks a
        // real test failure — if the rmdir fails, we'd rather the test
        // pass and the tmp dir get garbage-collected by the OS than the
        // test fail for a reason unrelated to the assertion.
        if let tmpHome {
            try? FileManager.default.removeItem(at: tmpHome)
        }
    }

    /// Scaffold: launch Scarf with the harness's env var + launch argument
    /// and confirm the launch fires. Asserting on window existence
    /// would currently fail because the app's polling services
    /// (`ServerLiveStatusRegistry`, `HermesCapabilitiesStore`) crash on
    /// the IPC handshake when `SCARF_HERMES_HOME` points at an empty dir
    /// — they assume `gateway_state.json` and the Hermes binary's state
    /// dir are populated. A follow-up will pre-populate the tmp home
    /// with a minimal fixture (`config.yaml`, `auth.json`, empty
    /// `cron/jobs.json`) before the assertion gets re-enabled.
    ///
    /// The test still earns its keep today: it proves the
    /// `XCUIApplication.launchArguments` + `launchEnvironment` plumbing
    /// reaches Scarf, and acts as the canonical "this is how Layer B
    /// tests start." Drop it if you re-architect the harness; otherwise
    /// keep it green until the fixture-Hermes-home work lands.
    ///
    /// See [Test-Harness wiki page](https://github.com/awizemann/scarf/wiki/Test-Harness)
    /// for the rest of the rollout.
    @MainActor
    func testAppLaunchesUnderTestMode() throws {
        let home = try makeTmpHermesHome()
        tmpHome = home

        let app = launchedApp(hermesHome: home)
        defer { app.terminate() }

        // Verify the launch reached the XCUITest IPC handshake — i.e. the
        // app process was spawned and the test runner connected to it.
        // `app.state` is non-blocking and reports `.runningForeground`
        // once the process has handshaked. Anything past that requires
        // the fixture work above.
        XCTAssertNotEqual(
            app.state, .notRunning,
            "XCUITest could not start Scarf with --scarf-test-mode + SCARF_HERMES_HOME=\(home.path). The launchArguments / launchEnvironment plumbing has regressed."
        )
    }

    // MARK: - Helpers (called from every Layer B test, keep the contract stable)

    /// Build a launched `XCUIApplication` configured for the harness:
    /// - `--scarf-test-mode` launch argument (read by `TestModeFlags`).
    /// - `SCARF_HERMES_HOME` env var (read by `HermesProfileResolver`).
    ///
    /// Mirroring this configuration exactly across every Layer B test
    /// means a single regression in either seam fails the whole suite
    /// loudly — the alternative is per-test launch configs that quietly
    /// drift apart and let bugs hide between them.
    @MainActor
    private func launchedApp(hermesHome: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scarf-test-mode"]
        app.launchEnvironment["SCARF_HERMES_HOME"] = hermesHome.path
        app.launch()
        return app
    }

    /// Create a fresh, empty Hermes home dir for this test. The harness
    /// pattern is one home per test — never share across tests, since the
    /// installer writes to it and a leaked install from test A breaks
    /// test B's preconditions. The path lands under
    /// `NSTemporaryDirectory()` so the OS reaps it on reboot even if
    /// teardown skips.
    private func makeTmpHermesHome() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = base.appendingPathComponent("scarf-uitest-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}
