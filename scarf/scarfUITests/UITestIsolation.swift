//
//  UITestIsolation.swift
//  scarfUITests
//
//  Shared isolation harness for every XCUITest in this target.
//
//  ## Why this file exists (load-bearing — read before adding a test)
//
//  A bare `XCUIApplication()` launches Scarf against the developer's
//  REAL `~/.hermes`, and everything the app writes there is permanent:
//  `scarf/projects.json` rows, cron jobs, sessions, memories. That
//  omission is how stale "HackerNews Daily Digest" rows ended up in the
//  real registry. Even a test that "only launches the app" is a writer —
//  Scarf runs migrations (`ProjectStore.derive()`) and refreshes
//  AGENTS.md blocks on launch.
//
//  So: EVERY test case in this target inherits `ScarfUITestCase`, and
//  every app instance comes from `makeApp()`, which pins
//  `SCARF_HERMES_HOME` (read by `HermesProfileResolver`, redirecting the
//  app's own file I/O) and `HERMES_HOME` (read by the `hermes` CLI that
//  `LocalTransport` spawns with the app's environment) at a per-test
//  throwaway home carrying the sentinel marker.
//

import XCTest

/// Base class for Scarf UI tests: mints a disposable Hermes home in
/// `setUpWithError`, deletes it in `tearDownWithError`, and vends
/// `XCUIApplication`s pinned to it.
class ScarfUITestCase: XCTestCase {

    /// Real user home — NOT `NSHomeDirectory()`, which inside the
    /// XCUITest runner sandbox returns
    /// `~/Library/Containers/com.scarfUITests.xctrunner/Data`. The Mac
    /// app itself runs unsandboxed and reads from `~/.hermes/`, so any
    /// path the harness checks against the same data must point at the
    /// un-sandboxed home. `getpwuid(getuid()).pw_dir` is the canonical
    /// UNIX answer.
    static let realHome: String = {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: dir)
    }()

    static let hermesBinary = (realHome as NSString)
        .appendingPathComponent(".local/bin/hermes")

    /// Sentinel filename `HermesProfileResolver` requires inside a
    /// `SCARF_HERMES_HOME` override before it will honor the override.
    /// Duplicated as a literal rather than imported from ScarfCore — the
    /// UI-test target links neither the app nor the package.
    static let testHomeMarkerFilename = ".scarf-test-home-marker"

    /// Throwaway Hermes home for the current test method. Every
    /// `XCUIApplication` this target launches gets pointed at it, so
    /// nothing the app-under-test writes can reach the developer's real
    /// `~/.hermes`.
    private(set) var isolatedHome: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        isolatedHome = try Self.makeIsolatedHermesHome()
    }

    override func tearDownWithError() throws {
        if let isolatedHome {
            try? FileManager.default.removeItem(atPath: isolatedHome)
        }
        isolatedHome = nil
        try super.tearDownWithError()
    }

    /// Build a disposable Hermes home under the runner's container tmp —
    /// chosen because the sandboxed runner can write it and the
    /// unsandboxed app can read/write it.
    ///
    /// Seeded with the sentinel marker plus best-effort copies of the
    /// dev Mac's `config.yaml` / `auth.json` / `.env`, so the app boots
    /// with realistic credentials while every WRITE —
    /// `scarf/projects.json`, `cron/jobs.json`, sessions, memories —
    /// lands in the throwaway copy.
    static func makeIsolatedHermesHome() throws -> String {
        let fm = FileManager.default
        let home = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("scarf-uitest-home-\(UUID().uuidString)")
        for sub in ["", "/scarf", "/cron", "/sessions", "/logs"] {
            try fm.createDirectory(atPath: home + sub, withIntermediateDirectories: true)
        }
        // Without this marker HermesProfileResolver ignores the override
        // outright and falls back to the real ~/.hermes.
        try Data().write(to: URL(fileURLWithPath: home + "/" + testHomeMarkerFilename))
        let realHermes = (realHome as NSString).appendingPathComponent(".hermes")
        for file in ["config.yaml", "auth.json", ".env"] {
            let src = (realHermes as NSString).appendingPathComponent(file)
            guard fm.fileExists(atPath: src) else { continue }
            // Copy rather than symlink so a write can never follow the
            // link back into the real home.
            try? fm.copyItem(atPath: src, toPath: home + "/" + file)
        }
        return home
    }

    /// An `XCUIApplication` pinned to this test's throwaway Hermes home.
    /// The ONLY sanctioned way to construct one in this target.
    func makeApp(extraLaunchArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scarf-test-mode"] + extraLaunchArguments
        app.launchEnvironment["SCARF_HERMES_HOME"] = isolatedHome
        app.launchEnvironment["HERMES_HOME"] = isolatedHome
        return app
    }
}
