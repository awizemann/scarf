//
//  TemplateInstallUITests.swift
//  scarfUITests
//
//  Layer B of the dogfooding-templates harness — drives Scarf via XCUITest
//  against a per-test throwaway Hermes home seeded from the developer
//  Mac's real installation.
//
//  ## Isolation (load-bearing — read before adding a test here)
//
//  `ScarfUITestCase` (see UITestIsolation.swift) is the base class for
//  every suite in this target; its `setUpWithError` mints
//  `<runner-tmp>/scarf-uitest-home-<uuid>/`, drops
//  the `.scarf-test-home-marker` sentinel in it, and copies over
//  `config.yaml` / `auth.json` / `.env` from the real `~/.hermes`. Every
//  app launch MUST go through `makeApp()`, which pins both
//  `SCARF_HERMES_HOME` (read by `HermesProfileResolver`, redirects the
//  app's own file I/O) and `HERMES_HOME` (read by the `hermes` CLI that
//  `LocalTransport` spawns with the app's environment). Constructing a
//  bare `XCUIApplication()` here launches Scarf against the developer's
//  REAL `~/.hermes` and its writes are permanent — that omission is
//  exactly how stale "HackerNews Daily Digest" rows ended up in the real
//  `~/.hermes/scarf/projects.json`.
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

final class TemplateInstallUITests: ScarfUITestCase {

    override func setUpWithError() throws {
        // Refuse to run if `hermes` isn't on the dev Mac. The harness's
        // whole premise is "validate against the real Hermes install
        // pre-release"; failing here is friendlier than letting tests
        // crash later in the install flow. Checked BEFORE super mints
        // the throwaway home so a skip leaves nothing behind.
        guard FileManager.default.isExecutableFile(atPath: Self.hermesBinary) else {
            throw XCTSkip("Hermes binary not found at \(Self.hermesBinary) — Layer B requires a real Hermes install on the dev Mac.")
        }
        // Isolation (throwaway `SCARF_HERMES_HOME`/`HERMES_HOME` + the
        // sentinel marker, and `makeApp()`) lives in `ScarfUITestCase`.
        try super.setUpWithError()
    }

    /// Smoke test: Scarf launches normally against the real Hermes home,
    /// the harness pushes ⌘1 (the "Open Server → Local" menu shortcut),
    /// and a window surfaces. This is the regression net for the test
    /// target itself — if a future change breaks XCUITest's ability to
    /// drive Scarf at all, this fails before any of the install-flow
    /// tests do.
    @MainActor
    func testAppLaunchesAndSurfacesAWindow() throws {
        let app = makeApp()
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
    /// `projects.json` — all inside this test's throwaway Hermes home
    /// (see `makeApp`), and all removed again by the in-app uninstall
    /// flow. Crashes mid-flow leak nothing durable: `tearDownWithError`
    /// deletes the throwaway home, cron job included, and the real
    /// `~/.hermes` is never a write target.
    ///
    /// **Cohabitation hazard — resolved by isolation.** This test used
    /// to run against the real `~/.hermes`, where a manually-installed
    /// copy of the same template (`awizemann/hackernews-digest`) made
    /// the installer uniquify the new project's name ("HackerNews Daily
    /// Digest 2") while registering BOTH projects' cron jobs under the
    /// same `[tmpl:awizemann/hackernews-digest] Daily HN digest` name.
    /// Since `ProjectTemplateUninstaller.loadUninstallPlan` resolves
    /// cron jobs to remove by NAME, the uninstall could target the
    /// user's real job — "test passes, your real cron disappears".
    /// The throwaway home starts empty, so there is nothing to collide
    /// with: the project installs under its exact manifest name and its
    /// cron job is the only one in that home. (The underlying
    /// resolve-by-name weakness in the uninstaller still exists and is
    /// worth fixing separately — cron-job IDs should be recorded in the
    /// lock file at install time and resolved by ID.)
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

        let app = makeApp(extraLaunchArguments: [
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
        ])
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
        // the human-readable manifest name and uniquifies only on
        // collision. This test's Hermes home is a fresh empty tmpdir,
        // so there is nothing to collide with and the row lands at the
        // exact manifest name — no numbered suffix. (Before isolation
        // this ran against the real `~/.hermes` and had to match a
        // suffix to avoid right-click-uninstalling the user's own
        // project; the user's data is sacred — see the v2.7
        // sentinel-marker incident report.) BEGINSWITH still, because
        // `.tag(project)` accessibility-id propagation has been flaky
        // in our hands; falls back to a tree dump for diagnostics.
        let projectRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'projects.row.HackerNews Daily Digest'"))
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

        print("[Layer B] isolated registry after install:",
              (try? String(contentsOfFile: isolatedHome + "/scarf/projects.json", encoding: .utf8)) ?? "<unreadable>")

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

        // 9. The project row disappears from the sidebar. It is the
        // only HN Digest project in this throwaway home, so the
        // assertion is unconditional. Re-query rather than reusing the
        // earlier handle because XCUITest sometimes caches a stale
        // snapshot of `.exists`.
        let removedDeadline = Date().addingTimeInterval(15)
        var stillThere = true
        while stillThere && Date() < removedDeadline {
            Thread.sleep(forTimeInterval: 0.5)
            stillThere = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'projects.row.HackerNews Daily Digest'"))
                .firstMatch.exists
        }
        if stillThere {
            let remaining = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'projects.row.'"))
                .allElementsBoundByIndex
                .map { $0.identifier }
            print("[Layer B] projects.row.* still present after uninstall:", remaining)
            let registry = (isolatedHome ?? "") + "/scarf/projects.json"
            let contents = (try? String(contentsOfFile: registry, encoding: .utf8)) ?? "<unreadable>"
            print("[Layer B] isolated registry after uninstall:", contents)
            let snap = XCTAttachment(screenshot: app.screenshot())
            snap.name = "row-still-present-after-uninstall"
            snap.lifetime = .keepAlways
            add(snap)
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
