//
//  TemplateInstallUITests.swift
//  scarfUITests
//
//  Layer B of the dogfooding-templates harness — drives Scarf via XCUITest
//  against the developer Mac's real `~/.hermes/` installation. v1 is
//  intentionally small: a single smoke test that proves the harness can
//  launch the app, surface a window, and read state. The install-flow
//  drive (Templates → Install → Configure → Dashboard) lands in v2 once
//  accessibility identifiers are wired across the install path.
//
//  ## Sandbox shape (load-bearing)
//
//  XCUITest runners on macOS are sandboxed even when the app under test
//  isn't. Concretely:
//
//  - The runner CAN read `~/.hermes/` (verified — `Data(contentsOf:)`
//    succeeds on `~/.hermes/scarf/projects.json`).
//  - The runner CANNOT write to `~/.hermes/` — attempting `try data.write(...)`
//    throws `NSCocoaErrorDomain Code=513 (NSFileWriteNoPermissionError)`
//    with underlying EPERM.
//  - The Mac app under test runs unsandboxed and writes there freely.
//
//  Implication for the harness: the install/uninstall round-trip MUST
//  happen via the app's own UI (which has the permissions), not via
//  direct file I/O from the runner. setUp can read state for assertions;
//  it can't snapshot-and-restore.
//
//  ## SwiftUI scene wiring
//
//  Scarf's main window is `WindowGroup(for: ServerID.self)`. On a fresh
//  `XCUIApplication.launch()` call, SwiftUI doesn't auto-surface a window
//  — real users get the window via Dock click → AppKit
//  `applicationOpenUntitledFile`, which XCUITest skips. The harness
//  nudges the same code path users hit by sending ⌘1 (the "Open Server →
//  Local" menu shortcut from `scarfApp.swift`'s `OpenServerCommands`).
//

import XCTest

final class TemplateInstallUITests: XCTestCase {

    /// Real user home — NOT `NSHomeDirectory()`, which inside the
    /// XCUITest runner sandbox returns
    /// `~/Library/Containers/com.scarfUITests.xctrunner/Data`. The Mac
    /// app itself runs unsandboxed and reads from `~/.hermes/`, so any
    /// path the harness checks against the same data must point at the
    /// un-sandboxed home. `getpwuid(getuid()).pw_dir` is the canonical
    /// UNIX answer.
    private static let realHome: String = {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: dir)
    }()

    private static let hermesBinary = (realHome as NSString)
        .appendingPathComponent(".local/bin/hermes")

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Refuse to run if `hermes` isn't on the dev Mac. The harness's
        // whole premise is "validate against the real Hermes install
        // pre-release"; failing here is friendlier than letting tests
        // crash later in the install flow.
        guard FileManager.default.isExecutableFile(atPath: Self.hermesBinary) else {
            throw XCTSkip("Hermes binary not found at \(Self.hermesBinary) — Layer B requires a real Hermes install on the dev Mac.")
        }
    }

    /// Smoke test: Scarf launches normally against the real Hermes home,
    /// the harness pushes ⌘1 (the "Open Server → Local" menu shortcut),
    /// and a window surfaces. This is the regression net for the test
    /// target itself — if a future change breaks XCUITest's ability to
    /// drive Scarf at all, this fails before any of the install-flow
    /// tests do.
    @MainActor
    func testAppLaunchesAndSurfacesAWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--scarf-test-mode"]
        app.launch()
        defer { app.terminate() }

        // Activate first — without this, ⌘1 is delivered to whatever
        // app currently owns the keyboard focus (often Xcode), and the
        // menu shortcut is silently dropped by Scarf.
        app.activate()
        // Brief pause for activation to settle. We sleep up to 1s; if
        // the app is already responsive sooner, the ⌘1 send is harmless.
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey("1", modifierFlags: .command)

        let windowAppeared = app.windows.firstMatch.waitForExistence(timeout: 15)
        XCTAssertTrue(
            windowAppeared,
            "Scarf did not surface a window within 15s of ⌘1 nudge. Crash logs land under derivedData/Logs/Test/."
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "App Launch"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
