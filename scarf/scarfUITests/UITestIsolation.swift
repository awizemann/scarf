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

    /// Optional env var naming a PREBUILT fixture Hermes home (seeded by
    /// `scripts/ui-fixture/make-ui-fixture.sh` with sessions, memories,
    /// paused cron jobs, kanban cards, a skill and a project — through the
    /// real `hermes` CLI, so the state.db schema matches the Hermes the
    /// app actually faces). When set, each test gets its OWN COPY of it;
    /// the original is never launched against, so a run can never mutate
    /// the cached fixture and no two tests share a home.
    ///
    /// Entirely optional: unset, or pointing at a directory that does not
    /// carry the sentinel marker, falls back to minting an empty home.
    /// The gate must never depend on the fixture existing.
    ///
    /// GOTCHA — how to actually set it from the command line: xcodebuild
    /// does NOT forward its own environment to the XCUITest RUNNER
    /// process, so `SCARF_UITEST_FIXTURE=… xcodebuild test` is silently
    /// ignored (verified: the fallback branch below never even logs).
    /// Prefix it — xcodebuild strips `TEST_RUNNER_` and passes the rest on:
    ///
    ///     TEST_RUNNER_SCARF_UITEST_FIXTURE=/path/to/fixture \
    ///       xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf \
    ///       -destination 'platform=macOS' -testPlan Smoke
    ///
    /// The same is true of every other runner-side variable, which is why
    /// `SCARF_UITEST_LIVE` is delivered by `Live.xctestplan` rather than
    /// by the shell.
    static let fixtureHomeEnvVar = "SCARF_UITEST_FIXTURE"

    /// Env var the Live test plan sets. See `requireLive()`.
    static let liveEnvVar = "SCARF_UITEST_LIVE"

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

        // Fixture path, when one was handed to us AND it is genuinely a
        // Scarf test home. The marker check is a safety interlock, not a
        // nicety: `HermesProfileResolver` honors `SCARF_HERMES_HOME` only
        // when the marker is present, so copying an unmarked directory
        // would produce a home every launch silently ignores — dropping
        // the run back onto the developer's real `~/.hermes`. The same
        // check is what makes `SCARF_UITEST_FIXTURE=~/.hermes` (typo, or
        // a well-meant "use my real data") refuse rather than obey.
        if let fixture = ProcessInfo.processInfo.environment[fixtureHomeEnvVar],
           !fixture.isEmpty {
            let marker = (fixture as NSString).appendingPathComponent(testHomeMarkerFilename)
            var isDir: ObjCBool = false
            let looksLikeAFixture = fm.fileExists(atPath: fixture, isDirectory: &isDir)
                && isDir.boolValue
                && fm.fileExists(atPath: marker)
            if looksLikeAFixture {
                // Copy, never symlink, and never launch against the
                // original: the app writes on launch (registry migration,
                // AGENTS.md refresh), so a shared fixture would drift
                // between tests and a symlinked write would escape.
                try fm.copyItem(atPath: fixture, toPath: home)
                return home
            }
            // Loud, because a typo'd fixture path degrading silently to
            // "empty home" turns a data-backed sweep into an empty-state
            // sweep that still passes.
            print("[ScarfUITestCase] \(fixtureHomeEnvVar)=\(fixture) is not a marked Scarf test home (no \(testHomeMarkerFilename)) — falling back to an empty isolated home.")
        }

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

    // MARK: - Launch / surface / quit

    /// Launch `app` and get a real window on screen — the only sequence
    /// that actually works for Scarf, owned here so no test re-derives it.
    ///
    /// Scarf's main window is `WindowGroup(for: ServerID.self)`. On a plain
    /// `XCUIApplication.launch()` SwiftUI does not auto-surface a window:
    /// real users get one via a Dock click → AppKit
    /// `applicationOpenUntitledFile`, a path XCUITest never takes. The
    /// harness nudges the same code path by sending ⌘1 ("Open Server →
    /// Local", from `scarfApp.swift`'s `OpenServerCommands`).
    ///
    /// Two ordering constraints make this fiddly enough to centralize:
    ///
    /// 1. `activate()` FIRST. Without it ⌘1 goes to whatever app owns the
    ///    keyboard (usually Xcode) and Scarf silently drops it.
    /// 2. Activation is not instant. We wait for `.runningForeground`
    ///    rather than sleeping — the old `Thread.sleep(1.0)` was slower
    ///    than needed on a warm Mac and too short on a cold one.
    ///
    /// The ⌘1 is re-sent (up to `attempts`) because a keystroke landing in
    /// the gap between "process is foreground" and "menu bar is installed"
    /// is dropped with no error — the most likely flake in this target.
    /// Re-sending is harmless: ⌘1 with a local window already open just
    /// focuses it.
    @discardableResult
    func launchAndSurface(_ app: XCUIApplication, attempts: Int = 3, timeout: TimeInterval = 24) -> Bool {
        app.launch()
        app.activate()
        waitForForeground(app, timeout: 15)

        let attempts = max(1, attempts)
        for attempt in 1...attempts {
            app.typeKey("1", modifierFlags: .command)
            if app.windows.firstMatch.waitForExistence(timeout: timeout / TimeInterval(attempts)) {
                return true
            }
            print("[ScarfUITestCase] no window after ⌘1 attempt \(attempt)/\(attempts); re-activating and retrying.")
            app.activate()
        }
        XCTFail("Scarf did not surface a window within \(timeout)s of the ⌘1 nudge. Crash logs land under derivedData/Logs/Test/.")
        return false
    }

    /// Poll until `app` reports `.runningForeground`.
    ///
    /// `XCTNSPredicateExpectation` POLLS (roughly once a second) instead of
    /// relying on KVO, which is what makes it usable against
    /// `XCUIApplication.state` — a property that posts no change
    /// notifications. Returns rather than failing: callers that care assert
    /// on the window, which is the outcome that matters.
    func waitForForeground(_ app: XCUIApplication, timeout: TimeInterval) {
        let foreground = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIApplication)?.state == .runningForeground
            },
            object: app
        )
        _ = XCTWaiter().wait(for: [foreground], timeout: timeout)
    }

    /// Quit `app` through its own ⌘Q instead of letting XCTest's implicit
    /// teardown force-terminate it.
    ///
    /// After long journeys with several sheet open/close cycles, the
    /// automatic terminate has been observed to fail with "Failed to
    /// terminate com.scarf.app:0" — a phantom failure on an otherwise green
    /// test. ⌘Q lets Scarf run its normal `NSApp.terminate` flow (including
    /// whatever window-state saving the `WindowGroup` wants) before the
    /// runner reaches for the hammer.
    func gracefulQuit(_ app: XCUIApplication, timeout: TimeInterval = 10) {
        guard app.state != .notRunning else { return }
        app.typeKey("q", modifierFlags: .command)
        let exited = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIApplication)?.state == .notRunning
            },
            object: app
        )
        _ = XCTWaiter().wait(for: [exited], timeout: timeout)
    }

    // MARK: - Screenshots

    /// A screenshot of Scarf's front window — never the whole desktop.
    ///
    /// On macOS `XCUIApplication.screenshot()` captures EVERY display,
    /// so a failure attachment in a result bundle would carry whatever
    /// else was on the developer's screen (mail, chats, other repos).
    /// Result bundles get shared; the window is all a triage needs.
    /// Falls back to the app capture only when no window exists yet,
    /// which is itself the thing worth seeing.
    func windowScreenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        let window = app.windows.firstMatch
        return window.exists ? window.screenshot() : app.screenshot()
    }


    // MARK: - Plan gating

    /// Skip unless the Live test plan is running.
    ///
    /// Live tests drive surfaces that need a running Hermes process or a
    /// real provider key (Chat over ACP, Gateway, Proxy, Bots, Curator).
    /// They are opt-in — `Live.xctestplan` sets `SCARF_UITEST_LIVE=1` — so
    /// Smoke and Full stay deterministic on a machine without credentials.
    /// Call this at the TOP of such a test, before any launch, so a skip
    /// leaves nothing behind.
    ///
    /// Read from the RUNNER's environment (where the test plan sets it),
    /// not from the app's launch environment.
    func requireLive() throws {
        let value = ProcessInfo.processInfo.environment[Self.liveEnvVar] ?? ""
        guard !value.isEmpty, value != "0" else {
            throw XCTSkip("Live-only test — run the Live test plan (which sets \(Self.liveEnvVar)=1) on a Mac with a real Hermes install and provider credentials.")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.hermesBinary) else {
            throw XCTSkip("Live-only test — no hermes binary at \(Self.hermesBinary).")
        }
    }
    // MARK: - Diagnostics

    /// Attach a screenshot of the app to the current test.
    ///
    /// `keepAlways` is the whole decision: a green run otherwise writes a
    /// full-screen PNG per step into every result bundle. Pass `false` for
    /// the "here is what it looked like" shots (deleted on success) and
    /// `true` only from a failure branch, where the image is the evidence.
    func attachScreenshot(_ app: XCUIApplication, named name: String, keepAlways: Bool) {
        let shot = XCTAttachment(screenshot: windowScreenshot(app))
        shot.name = name
        shot.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(shot)
    }

    // MARK: - Text entry

    /// Replace a text field's contents with `text`, then CHECK it landed —
    /// retrying the whole click/select-all/type sequence if it didn't.
    ///
    /// Why this exists rather than three inline calls: `typeText` on macOS
    /// synthesizes CGEvents into whatever is key at that instant, and when
    /// the app isn't frontmost (a sheet still animating in, the runner
    /// having just torn down a previous app) the call either fails outright
    /// with "Failed to synthesize event: Timed out while synthesizing
    /// event" or silently types into nothing. Observed on the template
    /// journey's parent-dir field, which is the first thing typed after a
    /// sheet presents. Both failure modes are transient, and both are
    /// invisible until an assertion far downstream fails for an unrelated-
    /// looking reason.
    ///
    /// So: activate the app first, type, then read the field's value back.
    /// A field that holds the right text has demonstrably received the
    /// events; one that doesn't gets another attempt before the test is
    /// allowed to fail. Fails the test at the CALL SITE (file/line of the
    /// caller) when every attempt is exhausted, naming what it saw.
    ///
    /// Not a sleep in disguise: there is no unconditional wait anywhere in
    /// here — a first attempt that works costs one extra value read.
    func setText(
        _ text: String,
        in element: XCUIElement,
        of app: XCUIApplication,
        attempts: Int = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lastSeen: String?
        for attempt in 1...max(1, attempts) {
            // `typeText` synthesizes CGEvents into whatever is key RIGHT
            // NOW: if Scarf is not `.runningForeground` the call raises
            // "Failed to synthesize event: Timed out while synthesizing
            // event", which XCTest records as a failure immediately — the
            // retry below never gets a turn. So the foreground check comes
            // BEFORE the typing, not around it.
            //
            // CONDITIONAL activate, deliberately. Calling `activate()`
            // unconditionally measurably made things WORSE: it is not free
            // when the app is already front, and when a SECOND UI-test run
            // is going on the same Mac (two agents, two DerivedData) the
            // two apps ping-pong for the frontmost slot and every step
            // slows to a crawl. Nothing here can fix a concurrent run
            // stealing focus — that is a "don't run two UI-test runs on
            // one Mac" problem, not a code one — but this at least does
            // not join in.
            if !app.isHittable {
                app.activate()
                waitForForeground(app, timeout: 10)
            }
            // And the field itself has to be on screen and hittable — a
            // sheet still animating in accepts a click that lands nowhere.
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"),
                object: element
            )
            _ = XCTWaiter().wait(for: [hittable], timeout: 10)

            let type = {
                element.click()
                element.typeKey("a", modifierFlags: .command)
                element.typeText(text)
            }
            // A dropped keystroke is one failure mode; the other is
            // `click`/`typeText` raising "Failed to synthesize event:
            // Timed out while synthesizing event", which XCTest records as
            // a test FAILURE the moment it happens — so a plain retry loop
            // never reaches its second attempt, it just reports the first
            // one's failure. Non-strict `XCTExpectFailure` around every
            // attempt BUT THE LAST makes the retry real, while the last
            // attempt runs unwrapped so a genuinely unusable field still
            // fails the test. Non-strict, so a clean attempt is not itself
            // an error.
            if attempt < attempts {
                let options = XCTExpectedFailure.Options()
                options.isStrict = false
                XCTExpectFailure(
                    "Transient event-synthesis failure typing into \(element.identifier) — retrying.",
                    options: options,
                    failingBlock: type
                )
            } else {
                type()
            }

            // A SwiftUI TextField reports its contents as the AX value;
            // an empty one can report the placeholder or nothing at all,
            // so compare against what we wanted rather than for emptiness.
            let seen = element.value as? String
            lastSeen = seen
            if seen == text { return }
            if attempt < attempts {
                // Re-clicking IS the retry; nothing to wait for. Logged so
                // flake that only shows up in CI is visible in the log
                // rather than inferred from a timing difference.
                print("[ScarfUITestCase] setText attempt \(attempt) did not land in \(element.identifier): saw \(seen ?? "<nil>")")
            }
        }
        XCTFail(
            "Could not type into \(element.identifier) after \(attempts) attempts — last value seen: \(lastSeen ?? "<nil>"). "
            + "Usually means the app was not frontmost when the events were synthesized.",
            file: file,
            line: line
        )
    }
}
