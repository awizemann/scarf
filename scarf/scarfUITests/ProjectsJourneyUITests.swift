//
//  ProjectsJourneyUITests.swift
//  scarfUITests
//
//  Depth for the Projects surface: the full create → registry → remove
//  round-trip through the real sheets, as a user does it.
//
//  ## What this adds over the sweep
//
//  `SectionSweepUITests` proves the Projects section RENDERS. It cannot
//  tell an empty registry from a broken one. This journey does the thing
//  a user actually opens Scarf to do — scaffold a project — and then
//  checks the two places the result has to show up:
//
//  1. the sidebar well (`sidebar.projects.row.<name>`), and
//  2. `<hermes-home>/scarf/projects.json`, the registry on disk.
//
//  Asserting BOTH is the point. A row that appears without a registry
//  write is a project that vanishes on relaunch; a registry write with no
//  row is a project the user can't reach. Either one alone passes while
//  the feature is broken.
//
//  ## Isolation
//
//  `ScarfUITestCase` (UITestIsolation.swift) is the base class and every
//  app instance comes from `makeApp()`, pinned to a per-test throwaway
//  Hermes home. That matters more here than anywhere else in this target:
//  this suite deliberately CREATES a project and REMOVES it again, and
//  both halves write `scarf/projects.json`. Against the developer's real
//  `~/.hermes` a mid-flow crash would leave a junk row in their registry —
//  which is exactly the incident that produced the isolation harness.
//
//  The scaffolded project directory lands in the runner's own container
//  tmp (writable by the sandboxed runner, readable/writable by the
//  unsandboxed app), and is deleted in a teardown block whether the test
//  passes, fails, or throws.
//
//  ## Deliberately hermes-free
//
//  Unlike `TemplateInstallUITests`, this suite does NOT require a `hermes`
//  binary. `ProjectScaffolder` is filesystem + registry work through the
//  context's transport, so the journey runs on a machine with no Hermes
//  install at all — and a gate step that runs everywhere is worth more
//  than one that skips.
//

import XCTest

final class ProjectsJourneyUITests: ScarfUITestCase {

    // MARK: - Fixtures

    /// Display name typed into the wizard. Also the sidebar row
    /// identifier suffix (`sidebar.projects.row.<name>`) and what we look
    /// for inside `projects.json`.
    ///
    /// Distinctive on purpose: the assertion against the registry is a
    /// substring check, and a name like "Test" would match half the JSON.
    /// The Hermes home is freshly minted per test, so there is nothing to
    /// collide with and no uniquifying suffix to account for.
    private static let projectName = "UI Gate Journey"

    /// Slug `NewProjectViewModel` derives from `projectName`
    /// (`ProjectScaffolder.suggestedSlug`). Asserted rather than assumed:
    /// if the derivation changes, this test should say so loudly instead
    /// of quietly checking the wrong directory.
    private static let expectedSlug = "ui-gate-journey"

    /// Parent directory the wizard scaffolds into. `/tmp` is
    /// sandbox-protected for the XCUITest runner (`createDirectory` throws
    /// EPERM); `NSTemporaryDirectory()` resolves to the runner's own
    /// container tmp, which the runner can write and the unsandboxed app
    /// can read and write.
    private var parentDir: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        parentDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("scarf-uitest-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )
        // A teardown block rather than a `defer` in the test body: this
        // runs even when a `try` in the test throws before its own defers
        // are installed, so the scaffolded tree can never outlive the run.
        let dir = parentDir!
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
    }

    // MARK: - Journey

    /// New Project wizard → sidebar row → registry on disk → Remove from
    /// List → row gone → registry clean.
    ///
    /// Identifiers exercised:
    ///
    ///   sidebar.section.Projects
    ///   sidebar.projects.newProject
    ///   newProject.name / newProject.parent / newProject.createButton
    ///   sidebar.projects.row.<name>
    ///   projects.contextMenu.removeFromList
    ///   projects.removeFromList.confirm
    ///
    /// **Side effects.** A real scaffolded project at
    /// `<runner-tmp>/scarf-uitest-projects-<uuid>/ui-gate-journey` and a
    /// real row in `<throwaway-home>/scarf/projects.json`. Both are inside
    /// per-test disposable directories; the real `~/.hermes` is never a
    /// write target (see `makeApp`).
    @MainActor
    func testCreateProjectAppearsInSidebarAndRegistryThenRemoves() throws {
        let app = makeApp()
        launchAndSurface(app)

        // The projects well is always in the sidebar, so this click is not
        // strictly required to reach the New Project button — but it puts
        // the Projects cockpit on screen, which is the state a user is in
        // when they create a project, and it is the click the sweep also
        // makes.
        let projectsSection = app.descendants(matching: .any)
            .matching(identifier: "sidebar.section.Projects").firstMatch
        XCTAssertTrue(
            projectsSection.waitForExistence(timeout: 15),
            "sidebar.section.Projects missing — the projects well never rendered."
        )
        projectsSection.click()

        // 1. Open the wizard from the well's footer button (not the
        // ellipsis menu: SwiftUI `Menu` items have been unreliable for
        // XCUITest in this app, which is why the template journey uses a
        // launch-arg bypass instead).
        let newProjectButton = app.descendants(matching: .any)
            .matching(identifier: "sidebar.projects.newProject").firstMatch
        XCTAssertTrue(
            newProjectButton.waitForExistence(timeout: 10),
            "sidebar.projects.newProject missing — the well's footer button is gone?"
        )
        newProjectButton.click()

        // 2. Name. The folder-name field auto-derives from this
        // (`NewProjectViewModel.projectName.didSet`), so it is left alone
        // — typing into it would flip `slugManuallyEdited` and stop
        // testing the derivation.
        let nameField = app.descendants(matching: .any)
            .matching(identifier: "newProject.name").firstMatch
        if !nameField.waitForExistence(timeout: 10) {
            attachScreenshot(app, named: "no-new-project-sheet", keepAlways: true)
            XCTFail("newProject.name missing — the New Project sheet didn't open. See screenshot.")
            return
        }
        setText(Self.projectName, in: nameField, of: app)

        // 3. Parent directory. THE isolation-critical field in this test:
        // it comes pre-filled with the user's own default (`~/Projects`),
        // and `canCommit` is satisfied by that default, so a keystroke
        // that fails to land would not fail the form — it would scaffold a
        // junk project into a real directory on the developer's Mac.
        // `SCARF_HERMES_HOME` does not isolate this: the parent directory
        // is an arbitrary path, not a Hermes-home-relative one.
        //
        // `setText` already fails the test when the value doesn't read
        // back, but this is the one place that guarantee must not be
        // action-at-a-distance, so it is re-asserted here — right before
        // the click that acts on it.
        let parentField = app.descendants(matching: .any)
            .matching(identifier: "newProject.parent").firstMatch
        XCTAssertTrue(parentField.waitForExistence(timeout: 5), "newProject.parent missing")
        setText(parentDir, in: parentField, of: app)
        XCTAssertEqual(
            parentField.value as? String, parentDir,
            "Parent directory field does not hold the throwaway path — REFUSING to create, "
            + "the wizard would scaffold into the developer's own default directory."
        )

        // 4. Create. The button is `.disabled(!canCommit)` until name,
        // a valid slug, and a parent directory are all present, so waiting
        // for it to be hittable also asserts the validation agreed with
        // what we typed.
        let createButton = app.descendants(matching: .any)
            .matching(identifier: "newProject.createButton").firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "newProject.createButton missing")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: createButton
        )
        if XCTWaiter().wait(for: [enabled], timeout: 10) != .completed {
            attachScreenshot(app, named: "create-button-disabled", keepAlways: true)
            XCTFail("newProject.createButton never enabled — did the name/parent text land in the fields?")
            return
        }
        createButton.click()

        // 5. The sidebar row. Commit is async (the scaffold runs off the
        // main actor through the transport) and the well only refreshes
        // after `onCreate` → `viewModel.reload()`, so this is a wait, not
        // a poll-once. Exact identifier, not BEGINSWITH: an empty registry
        // means no uniquifying suffix, and a surprise suffix here would be
        // a real bug worth failing on.
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.projects.row.\(Self.projectName)").firstMatch
        if !row.waitForExistence(timeout: 30) {
            print("[Projects journey] rows seen:", projectRowIdentifiers(in: app))
            print("[Projects journey] registry:", registryContents())
            attachScreenshot(app, named: "no-project-row-after-create", keepAlways: true)
            XCTFail("Created project never appeared in the sidebar.")
            return
        }

        // 6. The registry on disk, in the ISOLATED home. This is the half
        // the UI cannot fake: a row rendered from in-memory state with no
        // `projects.json` write is a project that disappears on relaunch.
        let afterCreate = registryContents()
        XCTAssertTrue(
            afterCreate.contains(Self.projectName),
            "projects.json in the isolated home has no row for \(Self.projectName): \(afterCreate)"
        )
        XCTAssertTrue(
            afterCreate.contains(Self.expectedSlug),
            "projects.json path doesn't use the derived slug '\(Self.expectedSlug)': \(afterCreate)"
        )
        // And the scaffolded tree itself — same reasoning one layer down.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: (parentDir as NSString).appendingPathComponent(Self.expectedSlug)
            ),
            "Scaffolder registered the project but created no directory at \(parentDir!)/\(Self.expectedSlug)"
        )

        attachScreenshot(app, named: "Post-Create Sidebar", keepAlways: false)

        // 7. Remove through the UI — right-click → "Remove from List
        // (keep files)…" → confirm. Deliberately the REMOVE path and not
        // "Uninstall Template…": this project has no template, so the
        // uninstall item is correctly absent from its menu.
        //
        // Attempted up to twice, because the three steps are three
        // synthesized events against a context menu and a confirmation
        // dialog, and any one of them can be swallowed on a busy Mac —
        // observed: the menu item clicked, the dialog presented, the
        // confirm click landed nowhere, and the row simply stayed. The
        // retry is safe: the whole sequence is idempotent (the project is
        // either still in the list or already gone), and re-running it
        // asserts the same thing. A second failure is a real one.
        var removed = false
        for attempt in 1...2 {
            row.rightClick()
            let removeItem = app.descendants(matching: .any)
                .matching(identifier: "projects.contextMenu.removeFromList").firstMatch
            if !removeItem.waitForExistence(timeout: 10) {
                attachScreenshot(app, named: "no-remove-menu-item", keepAlways: true)
                XCTFail("projects.contextMenu.removeFromList missing from the project's context menu.")
                return
            }
            removeItem.click()

            let confirmRemove = app.descendants(matching: .any)
                .matching(identifier: "projects.removeFromList.confirm").firstMatch
            if !confirmRemove.waitForExistence(timeout: 10) {
                attachScreenshot(app, named: "no-remove-confirm", keepAlways: true)
                XCTFail("projects.removeFromList.confirm missing — the confirmation dialog didn't present.")
                return
            }
            confirmRemove.click()

            // 8. The row goes away. `waitForExistence` only waits for
            // APPEARANCE; disappearance needs a predicate expectation,
            // which also re-snapshots the tree on each poll (a plain
            // `.exists` re-read can serve a stale snapshot).
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.descendants(matching: .any)
                    .matching(identifier: "sidebar.projects.row.\(Self.projectName)").firstMatch
            )
            if XCTWaiter().wait(for: [gone], timeout: 20) == .completed {
                removed = true
                break
            }
            print("[Projects journey] remove attempt \(attempt) left the row in place:",
                  projectRowIdentifiers(in: app))
        }
        if !removed {
            print("[Projects journey] rows still present:", projectRowIdentifiers(in: app))
            print("[Projects journey] registry:", registryContents())
            attachScreenshot(app, named: "row-still-present-after-remove", keepAlways: true)
            XCTFail("Project still in the sidebar after Remove from List.")
            return
        }

        // 9. …and out of the registry. "Remove from List" keeps the files
        // on disk by design, so only the registry row is asserted gone —
        // the directory staying put is the feature, not a leak.
        let afterRemove = registryContents()
        XCTAssertFalse(
            afterRemove.contains(Self.projectName),
            "projects.json still lists \(Self.projectName) after Remove from List: \(afterRemove)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: (parentDir as NSString).appendingPathComponent(Self.expectedSlug)
            ),
            "\"Remove from List (keep files)\" deleted the project directory — it must not touch disk."
        )

        // Graceful quit before XCTest's implicit force-terminate — see
        // `ScarfUITestCase.gracefulQuit` for why.
        gracefulQuit(app)
    }

    // MARK: - Helpers

    /// `scarf/projects.json` from THIS test's throwaway home, as a string.
    /// Returns a marker rather than throwing so it can be printed inside a
    /// failure branch without a second error path.
    private func registryContents() -> String {
        let path = (isolatedHome ?? "") + "/scarf/projects.json"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable: \(path)>"
    }

    private func projectRowIdentifiers(in app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.projects.row.'"))
            .allElementsBoundByIndex
            .map(\.identifier)
    }
}
