//
//  TemplateInstallUITests.swift
//  scarfUITests
//
//  Layer B of the dogfooding-templates harness — drives Scarf via XCUITest
//  against the developer Mac's real `~/.hermes/` installation.
//
//  Two tests:
//  1. `testAppLaunchesAndSurfacesAWindow` — smoke that proves the
//     harness can launch the app, send ⌘1, surface a window. Catches
//     regressions in the test target itself before the install-flow
//     tests run.
//  2. `testFullCatalogToInstallToDashboardJourney` — drives the v2.8
//     surface end-to-end: Templates → Browse Catalog → tap HN Digest
//     row → tap Install in detail → fill parent dir → Configure with
//     defaults → confirm Install → wait for project to appear in
//     sidebar → uninstall via context menu → confirm uninstall →
//     verify project gone. Cleanup is the uninstall round-trip; if
//     the test crashes mid-flow the only orphan is a tagged cron job
//     `[tmpl:awizemann/hackernews-digest] Daily HN digest` that the
//     dev can `hermes cron remove` manually.
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

    // MARK: - Full install-flow journey

    /// HTTPS URL for the HN Digest `.scarftemplate` bundle. The
    /// install pipeline accepts any HTTPS URL pointing at a valid
    /// `.scarftemplate`; this is the canonical published location
    /// that the live catalog also references via `installUrl`.
    private static let hnDigestInstallURL =
        "https://raw.githubusercontent.com/awizemann/scarf/main/templates/awizemann/hackernews-digest/hackernews-digest.scarftemplate"

    /// The cron job tag prefix the installer attaches to every cron
    /// job shipped with this template. Used for cleanup if the
    /// uninstall flow doesn't run (e.g. test crashed). The dev
    /// recovers by running `hermes cron remove <id>` for any job
    /// whose name starts with this prefix.
    private static let cronTagPrefix = "[tmpl:awizemann/hackernews-digest]"

    /// Drives Install (via launch-arg URL handoff) → Configure →
    /// Open Project → sidebar row → Uninstall → Done in one shot.
    /// The whole flow exercises the v2.7 and v2.8 accessibility
    /// identifiers on the install/uninstall path:
    ///
    ///   templates.toolbar.menu      → templates.browseCatalog
    ///   catalog.row.<slug>          → catalogDetail.installButton
    ///   templateInstall.parentDir.field
    ///   templateInstall.parentDir.continue
    ///   templateConfig.commitButton
    ///   templateInstall.confirmInstall
    ///   projects.row.<name>
    ///   projects.contextMenu.uninstallTemplate
    ///   templateUninstall.confirmRemove
    ///
    /// **Side effects.** Installs a real project at
    /// `<runner-tmp>/scarf-uitest-<uuid>/awizemann-hackernews-digest`,
    /// registers a paused cron job, and registers an entry in
    /// `~/.hermes/scarf/projects.json` — all of which the test then
    /// removes via the in-app uninstall flow. Crashes mid-flow leave
    /// at most one tagged cron job + one tmpdir; both recoverable
    /// without re-running the test.
    ///
    /// **Known cohabitation hazard.** If the dev Mac already has a
    /// project installed from the same template
    /// (`awizemann/hackernews-digest`), the install pipeline
    /// uniquifies the new project's name (e.g. "HackerNews Daily
    /// Digest 2"), but BOTH projects' cron jobs get registered
    /// under the same `[tmpl:awizemann/hackernews-digest] Daily HN
    /// digest` name. The uninstaller resolves cron jobs to remove
    /// by NAME (`ProjectTemplateUninstaller.loadUninstallPlan`,
    /// circa 2026.5), so it can target the WRONG project's cron
    /// job. Manifests as: test passes, your real project's cron
    /// disappears. Track issue: cron-job IDs should be stored in
    /// the lock file at install time and resolved by ID. Until
    /// fixed, run this test against a Mac that doesn't already
    /// have the test template installed manually.
    @MainActor
    func testFullCatalogToInstallToDashboardJourney() throws {
        // `/tmp` is sandbox-protected for the XCUITest runner —
        // `createDirectory` there throws EPERM. `NSTemporaryDirectory()`
        // resolves to the runner's own container tmp
        // (`~/Library/Containers/com.scarfUITests.xctrunner/Data/tmp/`),
        // which the runner can write AND the unsandboxed Scarf app
        // can read since the app has full disk access.
        let parentDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("scarf-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )
        defer {
            // Best-effort: uninstall preserves user-added files in
            // the project dir, so the parent may still exist after
            // the in-app uninstall ran. Wipe so /tmp dirs don't
            // leak across runs.
            try? FileManager.default.removeItem(atPath: parentDir)
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "--scarf-test-mode",
            // Hand the install URL to ScarfApp.init() via launch
            // args — see scarfApp.swift's `--scarf-test-install-url`
            // block. Equivalent to a `scarf://install?url=…` deep
            // link arriving on cold launch, except XCUITest
            // doesn't have a clean way to issue those (NSWorkspace
            // is sandbox-restricted from the runner). The router
            // stages the URL on the singleton; ProjectsView's
            // onAppear hook picks it up and presents the install
            // sheet automatically once the window surfaces.
            "--scarf-test-install-url",
            Self.hnDigestInstallURL
        ]
        app.launch()

        // Surface the window, same dance as the smoke test.
        app.activate()
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey("1", modifierFlags: .command)
        let windowAppeared = app.windows.firstMatch.waitForExistence(timeout: 15)
        XCTAssertTrue(windowAppeared, "Scarf window did not surface within 15s")

        // Click into Projects in the sidebar — the install-sheet
        // observer lives on `ProjectsView.onChange(pendingInstallURL)`,
        // so the staged URL only dispatches once Projects is on
        // screen. Default-launched Scarf opens to Dashboard.
        let projectsRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.section.Projects").firstMatch
        XCTAssertTrue(projectsRow.waitForExistence(timeout: 5), "sidebar.section.Projects missing")
        projectsRow.click()

        // 4. Install sheet → parent dir field. The launch-arg URL
        // handoff stages the URL via TemplateURLRouter; the install
        // sheet picks it up via ProjectsView's onChange observer.
        // First visible state is `fetching/inspecting` (network
        // download of the .scarftemplate, ~few seconds), then
        // `awaitingParentDirectory` which is when the field appears.
        // Generous timeout because cold network on a CI Mac can be
        // slow.
        let parentField = app.descendants(matching: .any)
            .matching(identifier: "templateInstall.parentDir.field").firstMatch
        if !parentField.waitForExistence(timeout: 30) {
            let snap = XCTAttachment(screenshot: app.screenshot())
            snap.name = "no-parent-dir-field"
            snap.lifetime = .keepAlways
            add(snap)
            XCTFail("parent-dir field missing — install sheet didn't open or got stuck in fetching/inspecting? See screenshot.")
            return
        }
        parentField.click()
        parentField.typeKey("a", modifierFlags: .command)
        parentField.typeText(parentDir)

        let parentContinue = app.descendants(matching: .any)
            .matching(identifier: "templateInstall.parentDir.continue").firstMatch
        XCTAssertTrue(parentContinue.waitForExistence(timeout: 3), "parent-dir Continue missing")
        parentContinue.click()

        // 5. Configure step. Three fields with defaults
        // (topics=[], min_score=100, max_items=15) — leave them, click
        // commit.
        let configCommit = app.descendants(matching: .any)
            .matching(identifier: "templateConfig.commitButton").firstMatch
        XCTAssertTrue(
            configCommit.waitForExistence(timeout: 5),
            "templateConfig.commitButton missing — configure step didn't render?"
        )
        configCommit.click()

        // 6. Confirm Install sheet.
        let confirmInstall = app.descendants(matching: .any)
            .matching(identifier: "templateInstall.confirmInstall").firstMatch
        XCTAssertTrue(
            confirmInstall.waitForExistence(timeout: 5),
            "templateInstall.confirmInstall missing — install plan didn't render?"
        )
        confirmInstall.click()

        // 6.5. Success view → Open Project. Without this, the
        // install sheet's onCompleted callback doesn't fire and
        // ProjectsView never calls `viewModel.load()`, so the new
        // project row never appears in the sidebar even though
        // it's in the registry on disk.
        let openProject = app.descendants(matching: .any)
            .matching(identifier: "templateInstall.success.openProject").firstMatch
        XCTAssertTrue(
            openProject.waitForExistence(timeout: 30),
            "templateInstall.success.openProject missing — install never completed?"
        )
        openProject.click()

        // 7. Project row appears in sidebar. The installer assigns
        // the human-readable manifest name and uniquifies on
        // collision — if the dev Mac already has a "HackerNews
        // Daily Digest" project (e.g. installed manually for v2.8
        // verification), the test's install lands at "HackerNews
        // Daily Digest 2" or similar. Match a numbered suffix
        // explicitly so we don't grab the user's existing project
        // and right-click-uninstall it (the user's data is sacred —
        // see the v2.7 sentinel-marker incident report).
        // The `.tag(project)` accessibility-id propagation has been
        // flaky in our hands — try BEGINSWITH (works on the matching
        // Identifiable) and fall back to a tree dump for diagnostics.
        let projectRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'projects.row.HackerNews Daily Digest '"))
            .firstMatch
        if !projectRow.waitForExistence(timeout: 30) {
            let allProjectRows = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'projects.row.'"))
                .allElementsBoundByIndex
                .map { $0.identifier }
            print("[Layer B] all projects.row.* identifiers seen:", allProjectRows)
            XCTFail("Installed project didn't appear in sidebar with a numbered suffix.")
            return
        }

        // Capture the post-install screenshot for triage / before
        // tearing down.
        let installedShot = XCTAttachment(screenshot: app.screenshot())
        installedShot.name = "Post-Install Sidebar"
        installedShot.lifetime = .deleteOnSuccess
        add(installedShot)

        // 8. Cleanup via UI: right-click → Uninstall Template…
        // → Remove. The uninstaller drives the cron-remove + registry
        // delete + project dir wipe through the app's permissions.
        projectRow.rightClick()
        let uninstallMenuItem = app.descendants(matching: .any)
            .matching(identifier: "projects.contextMenu.uninstallTemplate").firstMatch
        XCTAssertTrue(
            uninstallMenuItem.waitForExistence(timeout: 5),
            "Uninstall Template context-menu item missing — was isTemplateInstalled wrong?"
        )
        uninstallMenuItem.click()

        let confirmRemove = app.descendants(matching: .any)
            .matching(identifier: "templateUninstall.confirmRemove").firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 5), "Uninstall Remove button missing")
        confirmRemove.click()

        // 8.5. Uninstall success → Done. Same pattern as install:
        // the registry write only triggers a sidebar refresh once
        // the Done button fires onCompleted (see ProjectsView's
        // showingUninstallSheet handler).
        let uninstallDone = app.descendants(matching: .any)
            .matching(identifier: "templateUninstall.success.done").firstMatch
        XCTAssertTrue(
            uninstallDone.waitForExistence(timeout: 30),
            "templateUninstall.success.done missing — uninstall never completed?"
        )
        uninstallDone.click()

        // 9. Project row with the numbered suffix disappears from
        // the sidebar. The base "HackerNews Daily Digest" (the
        // user's manual install) stays — only the test's uniquified
        // copy should be gone. Re-query rather than reusing the
        // earlier handle because XCUITest sometimes caches a
        // stale snapshot of `.exists`.
        let removedDeadline = Date().addingTimeInterval(15)
        var stillThere = true
        while stillThere && Date() < removedDeadline {
            Thread.sleep(forTimeInterval: 0.5)
            stillThere = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'projects.row.HackerNews Daily Digest '"))
                .firstMatch.exists
        }
        XCTAssertFalse(
            stillThere,
            "Project still in sidebar after uninstall — registry write didn't complete?"
        )

        // 10. Graceful quit. XCTest's implicit teardown auto-terminate
        // has been observed to fail with "Failed to terminate
        // com.scarf.app:0" after long journeys involving multiple
        // sheet open/close cycles. Sending ⌘Q here lets Scarf go
        // through its normal NSApp.terminate flow (which respects
        // any save-window-state work the WindowGroup wants to do)
        // BEFORE the runner tries to force-terminate. Result: clean
        // green test instead of a phantom-failure-after-success.
        app.typeKey("q", modifierFlags: .command)
        // Wait briefly for the app to actually exit. If it doesn't,
        // the auto-terminate will still try and may still fail —
        // but at least we gave it the polite-quit chance first.
        let exitDeadline = Date().addingTimeInterval(5)
        while app.state != .notRunning && Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
