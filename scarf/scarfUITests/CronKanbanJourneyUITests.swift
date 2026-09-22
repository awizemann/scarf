//
//  CronKanbanJourneyUITests.swift
//  scarfUITests
//
//  The depth half of the UI release gate for the two sections that
//  MUTATE Hermes state: Cron and Kanban.
//
//  ## Why a journey and not a sweep
//
//  `SectionSweepUITests` proves every section renders. It cannot prove
//  that clicking "Save" in the cron editor actually wrote a job, that
//  "Pause" paused it, or that a card moved column — and those are the
//  interactions where Scarf is not merely a renderer but a WRITER,
//  driving the `hermes` CLI on the user's behalf.
//
//  ## The cross-check is the point
//
//  Every UI assertion here is paired with a read of the ground truth the
//  UI claims to be showing:
//
//  - Cron → `<isolatedHome>/cron/jobs.json`, the file Hermes owns and
//    Scarf's `CronViewModel` re-reads, plus `hermes cron list --all`
//    (paused jobs are invisible to a bare `cron list`).
//  - Kanban → `hermes kanban list`, since the board is driven entirely
//    through `hermes kanban … --json` (`KanbanService`) and never by
//    reading `kanban.db` directly.
//
//  A UI-only assertion would pass against a view that renders optimistic
//  local state and never reached the CLI at all — which is exactly the
//  class of bug charter C5 exists for. When the two disagree, that is a
//  product bug and this test says which side lied.
//
//  ## Isolation
//
//  `ScarfUITestCase` is the base class and `makeApp()` is the only way an
//  app is constructed here, so every write — jobs.json, kanban.db —
//  lands in the per-test throwaway home. The CLI calls this file makes
//  are pinned to the SAME home by passing `HERMES_HOME` explicitly in
//  `runHermes`; a bare `hermes kanban list` from the runner would read
//  the developer's real `~/.hermes`.
//
//  Two UserDefaults surfaces are forced through `NSArgumentDomain`
//  launch arguments rather than clicked, because `UserDefaults.standard`
//  is NOT covered by `SCARF_HERMES_HOME` and clicking would rewrite the
//  developer's own preferences: the sidebar section collapse keys (see
//  `SectionSweepUITests`) and `kanban.viewMode`, which `KanbanView`
//  reads with `@AppStorage` — a developer left on "List" would otherwise
//  run this journey against the read-only list view.
//
//  ## Fixture-optional
//
//  With `TEST_RUNNER_SCARF_UITEST_FIXTURE` set, the seeded rows (2 paused
//  cron jobs, 3 kanban cards one of which is blocked) are asserted too.
//  Without it the journeys still run end to end against an empty home —
//  the gate must never depend on the fixture existing.
//

import XCTest

final class CronKanbanJourneyUITests: ScarfUITestCase {

    // MARK: - Journey: Cron

    /// Create → verify → pause → verify → delete → verify, each step
    /// cross-checked against `cron/jobs.json`.
    @MainActor
    func testCronJobCreatePauseDelete() throws {
        warmHermesHome()
        let app = makeApp(extraLaunchArguments: Self.sidebarLaunchArguments + Self.windowFrameLaunchArguments + Self.animationLaunchArguments)
        launchAndSurface(app)
        defer { gracefulQuit(app) }
        requireWideWindow(app)

        openSection(app, "Cron")

        // --- Seeded rows (fixture only) -------------------------------
        let seeded = cronJobsOnDisk()
        if isFixtureRun {
            // The two jobs the fixture's "Seeding cron jobs" step makes,
            // asserted BY NAME rather than by a total — same reasoning as
            // the kanban board cards below: an exact count breaks the
            // moment the fixture seeds one more job for another suite,
            // even though nothing this journey depends on has changed.
            let seededNames = [
                "Fixture Morning Digest",
                "Fixture Link Check"
            ]
            let byName = Dictionary(seeded.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            for name in seededNames {
                guard let job = byName[name] else {
                    XCTFail("Fixture home should carry the seeded cron job '\(name)'; jobs.json has \(seeded.map(\.name)).")
                    continue
                }
                XCTAssertFalse(
                    job.enabled,
                    "Seeded fixture job '\(name)' is created-then-paused; jobs.json says \(seeded.map { "\($0.name)=\($0.enabled)" })."
                )
            }
            for job in seeded {
                XCTAssertTrue(
                    row(app, jobID: job.id).waitForExistence(timeout: 15),
                    "Seeded cron job \(job.name) (\(job.id)) is in jobs.json but no cron.row.\(job.id) rendered."
                )
            }
        } else {
            XCTAssertTrue(
                seeded.isEmpty,
                "Non-fixture run should start from an empty cron/jobs.json but found \(seeded.count) jobs — isolation leaked."
            )
        }

        // --- Create ---------------------------------------------------
        let idsBefore = Set(cronJobsOnDisk().map(\.id))
        // SHORT on purpose. Every synthesized keystroke re-renders the
        // sheet, and long strings lose characters (measured: a 20-char
        // name arrived as "-UI Gate Job B581826"). Eight characters is
        // still unique enough to identify one job.
        let jobName = "UIG-\(UUID().uuidString.prefix(4))"
        XCTContext.runActivity(named: "Create cron job") { _ in
            tap(app, "cron.newJob")

            let schedule = app.textFields.matching(identifier: "cron.editor.schedule").firstMatch
            XCTAssertTrue(schedule.waitForExistence(timeout: 25), "Cron create sheet never presented.")

            _ = fill(app.textFields.matching(identifier: "cron.editor.name").firstMatch, jobName)
            // `every 90m` is an interval, so Hermes computes a next_run
            // far enough out that nothing fires mid-test.
            type(into: schedule, "every 90m")
            type(into: app.textViews.matching(identifier: "cron.editor.prompt").firstMatch, "ok")

            let save = control(app, "cron.editor.save")
            XCTAssertTrue(save.waitForExistence(timeout: 20), "cron.editor.save never appeared.")
            // The editor disables Save while `schedule` is empty, and a
            // click on a disabled button is a silent no-op — which looks
            // exactly like "the app ignored my create".
            XCTAssertTrue(save.isEnabled, "Save is disabled — the Schedule field did not take the typed value.")
            save.click()
        }

        // Ground truth FIRST, and identified by DIFF rather than by name.
        //
        // Matching on the name we meant to type is a trap: synthesized
        // typing leaks between SwiftUI fields (measured — a job typed as
        // "UIG-9799" was created as "UIG-9799n", picking up a stray
        // keystroke from the next field), so a name mismatch fails the
        // journey for a create that actually worked. What the journey
        // really asserts is "clicking Save created exactly one job", and a
        // set difference says that precisely.
        var created: CronJob?
        XCTAssertTrue(
            waitUntil("cron create reaches jobs.json", timeout: 30) {
                let now = self.cronJobsOnDisk()
                created = now.first { !idsBefore.contains($0.id) }
                return created != nil
            },
            """
            `Save` created no new job in \
            \(self.isolatedHome ?? "<nil>")/cron/jobs.json within 30s. \
            jobs.json still holds: \(cronJobsOnDisk().map(\.name)). \
            cron.message says: '\(cronMessage(app))'. \
            On screen: \(visibleIdentifiers(app))
            """
        )
        let job = try XCTUnwrap(created)
        XCTAssertTrue(job.enabled, "A freshly created cron job should be enabled; jobs.json says otherwise.")
        // The form's values did reach the CLI. `contains`, not `==`,
        // because of the stray-keystroke leak described above.
        XCTAssertTrue(
            job.name.contains(jobName),
            "The created job is named '\(job.name)', which does not contain the '\(jobName)' typed into cron.editor.name — the Name field never reached `hermes cron create`."
        )

        let jobRow = row(app, jobID: job.id)
        XCTAssertTrue(
            jobRow.waitForExistence(timeout: 20),
            "Job \(job.id) is in jobs.json but cron.row.\(job.id) never rendered — the list did not reload."
        )
        attachScreenshot(app, named: "cron — created", keepAlways: false)

        // --- Pause and delete ------------------------------------------
        //
        // Driven through the row's CONTEXT MENU, with the paused state
        // read back off the ROW and off `cron/jobs.json` — the detail
        // pane's own Pause/Delete buttons are a second path to the same
        // view-model calls, and the row path also proves the row itself
        // takes a click.
        //
        // These steps were wrapped in `XCTExpectFailure(strict: false)`
        // while cron rows were unclickable (t-0fb3b91f: an unselected
        // row's background was `Color.clear`, so a `.plain` Button's hit
        // area was its glyphs only, and the detail pane consequently had
        // nothing selected to show). The wrapper is gone — these assert
        // for real.
        // --- Pause ----------------------------------------------------
        //
        // The row speaks its own state ("<name>, paused"), so the pause is
        // asserted on the row, on `cron/jobs.json` and on the CLI.
        XCTAssertFalse(
            jobRow.label.lowercased().contains("paused"),
            "A freshly created job should not read as paused, but the row says '\(jobRow.label)'."
        )

        jobRow.rightClick()
        let pauseItem = app.menuItems.matching(identifier: "cron.contextMenu.pauseToggle").firstMatch
        XCTAssertTrue(pauseItem.waitForExistence(timeout: 15),
                      "The cron row's context menu offered no Pause item. On screen: \(visibleIdentifiers(app))")
        pauseItem.click()

        XCTAssertTrue(
            waitUntil("cron pause reaches jobs.json", timeout: 30) {
                self.cronJobsOnDisk().first { $0.id == job.id }?.enabled == false
            },
            "Pausing did not flip enabled=false for \(job.id) in cron/jobs.json. cron.message says: '\(cronMessage(app))'."
        )
        // The same fact through the CLI, in BOTH listings.
        //
        // A paused job is visible in a bare `hermes cron list`, badged
        // `[paused]`; `--all` widens the listing to disabled and completed
        // jobs on top of that. Verified against the installed CLI's own
        // source (`hermes_cli/cron.py:168-176`): `cron_list` reads
        // `list_jobs(include_disabled=True)` and, without `--all`, keeps
        // every job that is `enabled` OR whose effective state is
        // `paused`.
        //
        // This test used to assert the opposite — that the bare form HIDES
        // a paused job — which was true when it was written (2026-09-08).
        // Upstream Hermes `3f399c0bd4` ("fix(cli): align kanban edit and
        // paused cron listing", in v0.21.4) changed `cron_list` from
        // `list_jobs(include_disabled=show_all)` to the filter above, so
        // the old assertion failed on a CORRECT current host. Scarf's own
        // cron UI reads `cron/jobs.json`, never this output, so nothing in
        // the app moved with it.
        //
        // Both reads are scoped to the job's OWN line ("<id> [paused]" is
        // one row of the listing). A bare `contains(id) && contains(...)`
        // over the whole listing would pass on some OTHER job's badge —
        // the fixture home seeds two paused cron jobs of its own, so that
        // weaker form asserts almost nothing here.
        let listedAll = runHermes(["cron", "list", "--all"]).stdout
        XCTAssertTrue(
            pausedBadgeLine(for: job.id, in: listedAll) != nil,
            "`hermes cron list --all` does not show \(job.id) as paused:\n\(listedAll)"
        )
        let listedBare = runHermes(["cron", "list"]).stdout
        XCTAssertTrue(
            pausedBadgeLine(for: job.id, in: listedBare) != nil,
            "A paused job should still be listed, badged [paused], by a bare `hermes cron list`, but \(job.id) is not:\n\(listedBare)"
        )

        XCTAssertTrue(
            waitUntil("paused state reaches the row", timeout: 25) {
                jobRow.exists && jobRow.label.lowercased().contains("paused")
            },
            "jobs.json says \(job.id) is paused but its row still reads '\(jobRow.label)' — the UI is showing stale state."
        )
        attachScreenshot(app, named: "cron — paused", keepAlways: false)

        // --- Delete ---------------------------------------------------
        jobRow.rightClick()
        // By identifier: the Edit menu also carries a "Delete" item.
        let deleteItem = app.menuItems.matching(identifier: "cron.contextMenu.delete").firstMatch
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 15),
                      "The cron row's context menu offered no Delete item.")
        deleteItem.click()

        // The confirmation is a SwiftUI `confirmationDialog`, which macOS
        // renders as an alert whose buttons are addressed by label — an
        // identifier applied in the dialog builder does not survive the
        // AppKit bridge.
        let confirmDelete = app.sheets.buttons.matching(NSPredicate(format: "label == %@", "Delete")).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 15),
                      "Delete confirmation dialog never appeared.")
        confirmDelete.click()

        XCTAssertTrue(
            waitUntil("cron remove reaches jobs.json", timeout: 30) {
                !self.cronJobsOnDisk().contains { $0.id == job.id }
            },
            "Confirming Delete did not remove \(job.id) from cron/jobs.json. cron.message says: '\(cronMessage(app))'."
        )
        XCTAssertFalse(runHermes(["cron", "list", "--all"]).stdout.contains(job.id),
                       "`hermes cron list --all` still lists the deleted job \(job.id).")
        XCTAssertTrue(
            waitUntil("deleted row disappears", timeout: 25) { !jobRow.exists },
            "\(job.id) is gone from jobs.json but cron.row.\(job.id) is still on screen."
        )


        // The fixture's own jobs must survive a journey that only ever
        // touched its own job.
        if isFixtureRun {
            XCTAssertEqual(Set(cronJobsOnDisk().map(\.id)), Set(seeded.map(\.id)),
                           "The journey disturbed the seeded fixture jobs.")
        }

        XCTAssertNotEqual(app.state, .notRunning, "Scarf terminated during the cron journey.")
    }

    // MARK: - Journey: Kanban

    /// Create a card → verify it lands in Up Next → move it to Blocked
    /// through the inspector → verify the column change, each step
    /// cross-checked against `hermes kanban list`.
    ///
    /// The move is done through the inspector's Block button rather than
    /// by dragging a card between columns: `KanbanColumnView` accepts a
    /// `dropDestination`, but a synthesized XCUITest drag is the single
    /// flakiest gesture on macOS and the two paths converge on the same
    /// `KanbanBoardViewModel.attemptMove` call, so the menu path tests
    /// the same contract without the flake.
    @MainActor
    func testKanbanCardCreateAndMoveColumn() throws {
        // `kanban.db` is created lazily. `init` is idempotent (VERBS.md)
        // and is setup, not an assertion — an empty home would otherwise
        // fail on the first `list` rather than on anything the UI did.
        let initResult = runHermes(["kanban", "init"])
        try XCTSkipUnless(initResult.code == 0,
                          "Could not initialize a kanban board in the isolated home: \(initResult.stderr)")

        warmHermesHome()
        let app = makeApp(extraLaunchArguments: Self.sidebarLaunchArguments + Self.boardModeLaunchArguments + Self.windowFrameLaunchArguments + Self.animationLaunchArguments)
        launchAndSurface(app)
        defer { gracefulQuit(app) }
        requireWideWindow(app)

        // Kanban is capability-gated (`HermesCapabilities.hasKanban`), so
        // a legitimately older host has no row. Skipping beats failing a
        // correct machine — same rule the section sweep follows.
        //
        // The groups MUST be expanded before this check, or a shut
        // "Manage" group reads as "the host is too old" and the journey
        // skips itself on a perfectly capable Mac.
        assertAllSidebarSectionsExpanded(app)
        scrollSidebarToward(app, identifier: "sidebar.section.Kanban")
        let sidebarRow = app.descendants(matching: .any)
            .matching(identifier: "sidebar.section.Kanban").firstMatch
        // Generous on purpose. `HermesCapabilities` probes `hermes
        // --version` in a subprocess AFTER first paint, so for the first
        // several seconds of a cold launch the row is missing for a
        // reason that has nothing to do with the host's version. A short
        // window here made this journey skip itself on a Mac where the
        // section sweep sees Kanban render fine.
        try XCTSkipUnless(sidebarRow.waitForExistence(timeout: 180),
                          """
                          No Kanban sidebar row after 180 s. Either the host Hermes predates the \
                          Kanban capability (a legitimate skip), or its version probe failed: \
                          `HermesCapabilitiesStore` probes `hermes --version` exactly ONCE at \
                          window init and never retries, and `HermesVersionCache` keys its \
                          persisted answer on the Hermes home path — so an isolated test home is \
                          always a cold probe with no second chance. Observed both ways on the \
                          same Mac, minutes apart.
                          """)
        openSection(app, "Kanban")

        // --- Seeded cards (fixture only) ------------------------------
        let seeded = kanbanTasks()
        if isFixtureRun {
            // The three BOARD cards the "Seeding kanban cards" step makes,
            // asserted by title rather than by a total count.
            //
            // A count was the original spelling and it broke the moment the
            // fixture grew: the "Seeding chat-scoped kanban tasks" step adds
            // four more cards (a running + a review card for each of two
            // chats, stamped with a `session_id` for the chat badge journey),
            // so `kanban list` reports 7 on one global board and `== 3`
            // failed on a fixture that was entirely correct. Naming the rows
            // this journey actually depends on says what is meant and lets
            // the fixture keep growing for other suites.
            let boardCardTitles = [
                "Fixture: wire up the sweep",
                "Fixture: blocked on review",
                "Fixture: triage the backlog"
            ]
            let seededTitles = Set(seeded.map(\.title))
            for title in boardCardTitles {
                XCTAssertTrue(
                    seededTitles.contains(title),
                    "Fixture home should carry the seeded kanban card '\(title)'; `kanban list` reports \(seeded.map(\.title))."
                )
            }
            for task in seeded {
                XCTAssertTrue(card(app, taskID: task.id).waitForExistence(timeout: 20),
                              "Seeded card \(task.title) (\(task.id)) is in `kanban list` but kanban.card.\(task.id) never rendered.")
            }
            let blocked = try XCTUnwrap(seeded.first { $0.status == "blocked" },
                                        "The fixture seeds exactly one blocked card; `kanban list` shows none.")
            XCTAssertTrue(
                cardIsIn(app, taskID: blocked.id, column: "blocked", timeout: 20),
                "`kanban list` says \(blocked.id) is blocked but its card is not inside kanban.column.blocked; it renders in \(columnsContaining(app, taskID: blocked.id))."
            )
        } else {
            XCTAssertTrue(seeded.isEmpty,
                          "Non-fixture run should start from an empty board but `kanban list` shows \(seeded.count) cards — isolation leaked.")
        }

        // --- Create ---------------------------------------------------
        let taskIDsBefore = Set(kanbanTasks().map(\.id))
        var title = "UIC-\(UUID().uuidString.prefix(4))"
        XCTContext.runActivity(named: "Create kanban card") { _ in
            tap(app, "kanban.newTask")

            let titleField = app.textFields.matching(identifier: "kanban.create.title").firstMatch
            XCTAssertTrue(titleField.waitForExistence(timeout: 25), "Kanban create sheet never presented.")
            title = fill(titleField, title)

            tap(app, "kanban.create.submit")
        }

        var createdTask: KanbanTask?
        // By DIFF, not by title — same reason as the cron journey: a
        // synthesized keystroke can leak between fields, and a title
        // mismatch would fail a create that in fact succeeded.
        let landed = waitUntil("kanban create reaches the CLI", timeout: 30) {
            createdTask = self.kanbanTasks().first { !taskIDsBefore.contains($0.id) }
            return createdTask != nil
        }
        if !landed {
            // Keep this one: a create that never reached the CLI usually
            // left its reason on screen (the sheet's submit error, or the
            // board's toolset-disabled banner), and a screenshot is the
            // only place that survives the run.
            attachScreenshot(app, named: "kanban — create did not land", keepAlways: true)
        }
        XCTAssertTrue(
            landed,
            """
            `Create task` produced no new card. \
            `hermes kanban list` holds: \(kanbanTasks().map(\.title)). \
            On screen: \(visibleIdentifiers(app))
            """
        )

        let task = try XCTUnwrap(createdTask)
        XCTAssertNotEqual(task.status, "blocked", "A newly created card should not start blocked.")
        XCTAssertTrue(
            task.title.contains(title),
            "The created card is titled '\(task.title)', which does not contain the '\(title)' typed into kanban.create.title."
        )

        // The board polls every five seconds, so the card appears without
        // any nudge — but that also means this needs a real wait, not an
        // immediate `exists`.
        XCTAssertTrue(
            cardIsIn(app, taskID: task.id, column: "upNext", timeout: 30),
            "`hermes kanban list` says \(task.id) is '\(task.status)' but its card is not inside kanban.column.upNext; it renders in \(columnsContaining(app, taskID: task.id))."
        )
        attachScreenshot(app, named: "kanban — created", keepAlways: false)

        // --- Move column ----------------------------------------------
        XCTContext.runActivity(named: "Move card to Blocked") { _ in
            card(app, taskID: task.id).click()

            let block = control(app, "kanban.inspector.block")
            XCTAssertTrue(block.waitForExistence(timeout: 20),
                          "Inspector never opened (or offered no Block action) for \(task.id).")

            // Click Block until its sheet is actually up. The board polls
            // every five seconds and rebuilds the inspector under us; a
            // click that lands on a view being replaced sets no
            // `blockSheetTaskId` at all — observed as an inspector still
            // showing Block, and no sheet, 25 s later.
            let confirm = control(app, "kanban.block.confirm")
            var sheetUp = false
            for attempt in 1...5 where !sheetUp {
                if app.state != .runningForeground { app.activate() }
                if block.exists { block.click() }
                sheetUp = confirm.waitForExistence(timeout: 6)
                if !sheetUp {
                    print("[journey] Block click \(attempt)/5 did not present the block-reason sheet; retrying.")
                }
            }
            XCTAssertTrue(sheetUp, "Block-reason sheet never presented. On screen: \(visibleIdentifiers(app))")
            // A reason is REQUIRED (KanbanService.plan rejects an empty one
            // for Ready→Blocked); the sheet keeps Block disabled until typed.
            let reasonField = control(app, "kanban.block.reason")
            XCTAssertTrue(reasonField.waitForExistence(timeout: 5), "Block sheet has no kanban.block.reason field.")
            type(into: reasonField, "UI gate")
            XCTAssertTrue(
                waitUntil("Block button enabled after typing a reason", timeout: 5) { confirm.isEnabled },
                "kanban.block.confirm stayed disabled after typing a reason."
            )
            confirm.click()
        }

        XCTAssertTrue(
            waitUntil("kanban block reaches the CLI", timeout: 30) {
                self.kanbanTasks().first { $0.id == task.id }?.status == "blocked"
            },
            "Blocking through the inspector did not move \(task.id) to blocked; `hermes kanban list` says '\(kanbanTasks().first { $0.id == task.id }?.status ?? "<gone>")'. Board error banner: \(kanbanError(app))."
        )
        XCTAssertTrue(
            cardIsIn(app, taskID: task.id, column: "blocked", timeout: 30),
            "`hermes kanban list` says \(task.id) is blocked but its card is not inside kanban.column.blocked; it renders in \(columnsContaining(app, taskID: task.id))."
        )
        XCTAssertFalse(
            cardIsIn(app, taskID: task.id, column: "upNext", timeout: 3),
            "\(task.id) moved to Blocked but a copy is still rendering in Up Next."
        )
        attachScreenshot(app, named: "kanban — blocked", keepAlways: false)

        if isFixtureRun {
            XCTAssertEqual(Set(kanbanTasks().map(\.id)).subtracting([task.id]), Set(seeded.map(\.id)),
                           "The journey disturbed the seeded fixture cards.")
        }

        XCTAssertNotEqual(app.state, .notRunning, "Scarf terminated during the kanban journey.")
    }

    // MARK: - Launch arguments

    /// Sidebar sections forced open, borrowed from the sweep so there is
    /// one definition of the collapse keys in this target.
    static var sidebarLaunchArguments: [String] { SectionSweepUITests.expandedSidebarLaunchArguments }

    /// `KanbanView` remembers Board vs List in `@AppStorage("kanban.viewMode")`,
    /// i.e. in `UserDefaults.standard`, which `SCARF_HERMES_HOME` does NOT
    /// isolate. Pinning it through `NSArgumentDomain` makes the journey
    /// independent of whichever mode the developer last used, and — unlike
    /// clicking the picker — is never written back to their preferences.
    static let boardModeLaunchArguments = ["-kanban.viewMode", "board"]

    /// Pin the window's geometry for the app under test.
    ///
    /// The third UserDefaults surface this journey has to neutralize, and
    /// the one that cost the most to find. `WindowFrameAutosave` restores
    /// the window's last frame from `UserDefaults.standard` and writes it
    /// back on every resize/move — so the gate's outcome depended on how
    /// big the developer had last left their Scarf window: at a narrow
    /// saved size, `CronView`'s detail pane was clipped out of existence
    /// and the journey failed on a correct build. Worse, sizing the window
    /// from inside the test (Window ▸ Zoom) PERSISTED into the developer's
    /// own preferences — the exact side effect the sidebar-collapse launch
    /// arguments exist to avoid.
    ///
    /// An `NSArgumentDomain` value out-ranks the persisted one and is never
    /// written back, so the app under test always gets a window big enough
    /// for a wide surface and the developer's remembered geometry is left
    /// alone. The value is `NSStringFromRect` format, which is what
    /// `NSRectFromString` on the other side expects.
    /// Turn off AppKit's window/sheet animations for the app under test.
    ///
    /// `typeText` waits for the app to go quiescent before synthesizing
    /// keystrokes, and an animation in flight is not quiescent — which
    /// surfaces as "Failed to synthesize event: Timed out while
    /// synthesizing event", an unrecoverable failure. Sheet presentation is
    /// exactly such an animation, and both journeys type into a sheet.
    /// `NSArgumentDomain` again: nothing is persisted.
    static let animationLaunchArguments: [String] = []

    /// Provided by `makeApp()` now; kept so the launch sites read unchanged.
    static let windowFrameLaunchArguments: [String] = []

    // MARK: - Warm-up

    /// Pay Hermes's first-run cost for the isolated home BEFORE launching
    /// the app.
    ///
    /// `HermesCapabilitiesStore` probes `hermes --version` exactly once, at
    /// window-init, and never retries: if that probe is still running when
    /// the sidebar renders, the capability-gated rows (Kanban among them)
    /// are simply absent, and a test waiting on one cannot tell that from
    /// "this host is too old". Against a brand-new `HERMES_HOME` the first
    /// CLI call does first-run initialization and is slow enough to lose
    /// that race — which is exactly what made this journey skip itself.
    /// Running the same command from the runner first makes the app's probe
    /// a warm, fast one.
    private func warmHermesHome() {
        let result = runHermes(["--version"], timeout: 180)
        print("[journey] warmed isolated home: exit \(result.code) \(result.stdout.split(separator: "\n").first ?? "")")
    }

    // MARK: - Window

    /// Zoom the window to fill the screen, through the app's own
    /// Window ▸ Zoom menu item.
    ///
    /// Not cosmetic. Both surfaces this file drives are WIDE: `CronView`
    /// is an `HSplitView` of a 320-pt list and a 400-pt detail pane, and
    /// the Kanban board lays several columns of 240 pt minimum side by
    /// side. At the window size XCUITest launches, the cron detail pane
    /// was clipped entirely out of view — and a clipped SwiftUI subtree is
    /// not in the accessibility tree at all, so "click the row, wait for
    /// the detail pane" failed with the pane simply absent while the row
    /// was demonstrably present. Widening the window is the fix; weakening
    /// the assertion would only have been testing the clip.
    /// Assert the window is wide enough for the surface under test.
    ///
    /// The SIZE itself comes from `Self.windowFrameLaunchArguments`, not
    /// from a gesture — see there for why. This only verifies it took, so a
    /// future change to the persistence key fails here with a readable
    /// message instead of ten screens later as "the detail pane never
    /// opened".
    private func requireWideWindow(_ app: XCUIApplication, minimumWidth: CGFloat = 1500) {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 15) else {
            XCTFail("No window.")
            return
        }
        let frame = window.frame
        print("[journey] window frame: \(frame)")
        XCTAssertGreaterThanOrEqual(
            frame.width, minimumWidth,
            """
            Window is only \(frame.width)pt wide. Cron's HSplitView (320 + 400) and \
            the Kanban board's columns need more, and a clipped SwiftUI subtree is \
            absent from the accessibility tree entirely. Did the \
            `\(Self.windowFramePersistenceKey)` launch argument stop matching \
            WindowFrameAutosave's key?
            """
        )
    }

    // MARK: - Section navigation

    /// Open a section by clicking its sidebar row and waiting for the
    /// routed root.
    ///
    /// Expands the nav groups first, EVERY time: Cron and Kanban both
    /// live under groups `SidebarSectionCollapseStore` collapses by
    /// default, and the launch-argument override alone was not enough on
    /// a real run — the first version of this journey failed with
    /// "sidebar.section.Cron never appeared" and Kanban skipped itself as
    /// capability-gated, when in fact both groups were simply shut.
    private func openSection(_ app: XCUIApplication, _ rawValue: String) {
        assertAllSidebarSectionsExpanded(app)
        let row = app.descendants(matching: .any)
            .matching(identifier: "sidebar.section.\(rawValue)").firstMatch
        if !row.waitForExistence(timeout: 20) {
            scrollSidebarToward(app, identifier: "sidebar.section.\(rawValue)")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sidebar.section.\(rawValue) never appeared, even after scrolling the sidebar. On screen: \(visibleIdentifiers(app))")
        row.click()
        let root = app.descendants(matching: .any)
            .matching(identifier: "\(rawValue).root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 25), "\(rawValue).root never rendered after clicking its sidebar row.")
    }

    /// Scroll the sidebar down until `identifier` is in the tree.
    ///
    /// With every nav group expanded the sidebar is taller than the window
    /// on a normal display, and the rows at the bottom (Cron, Health, Logs,
    /// Settings) are then not merely off-screen — they are absent from the
    /// accessibility tree, so `waitForExistence` waits out its full timeout
    /// and reports the section as missing. Scrolling is the difference
    /// between a real gate and one that only passes on a huge monitor.
    private func scrollSidebarToward(_ app: XCUIApplication, identifier: String, steps: Int = 8) {
        // The sidebar is the narrow scrollable column; anything wide is the
        // detail pane, and scrolling THAT would move the wrong content.
        let candidates = (app.scrollViews.allElementsBoundByIndex
            + app.outlines.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex)
            .filter { $0.exists && $0.frame.width > 0 && $0.frame.width < 420 }
        guard let sidebar = candidates.first else {
            print("[journey] no narrow scrollable found — cannot scroll the sidebar.")
            return
        }
        let target = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for step in 1...max(1, steps) {
            if target.exists { return }
            sidebar.scroll(byDeltaX: 0, deltaY: -120)
            print("[journey] scrolled the sidebar (\(step)/\(steps)) looking for \(identifier).")
        }
    }

    /// The Kanban board's error banner text, or "<none>".
    private func kanbanError(_ app: XCUIApplication) -> String {
        let banner = app.descendants(matching: .any).matching(identifier: "kanban.error").firstMatch
        return banner.exists ? banner.label : "<none>"
    }

    /// The Cron page header's status/error line, or "<none>".
    ///
    /// `CronViewModel.post` puts every failed `hermes cron …` here and (for
    /// failures) never auto-clears it, so it is the app's own account of
    /// why a mutation did not happen.
    private func cronMessage(_ app: XCUIApplication) -> String {
        let message = app.descendants(matching: .any)
            .matching(identifier: "cron.message").firstMatch
        return message.exists ? message.label : "<none>"
    }

    // MARK: - Element lookups

    /// Wait for the element carrying `identifier`, then click it.
    ///
    /// Never click without waiting: SwiftUI publishes a section's root
    /// before the rest of its chrome is in the accessibility tree, so a
    /// bare `.click()` right after `openSection` raced the header into
    /// existence and failed with a bare "No matches found" that says
    /// nothing about why. On a miss this dumps every identifier the app
    /// IS exposing, which is the difference between a two-minute rerun
    /// and a guess.
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20) {
        let any = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard any.waitForExistence(timeout: timeout) else {
            XCTFail("No element with identifier '\(identifier)' after \(timeout)s. On screen: \(visibleIdentifiers(app))")
            return
        }
        control(app, identifier).click()
    }

    /// Every non-empty identifier currently in the app's accessibility
    /// tree — diagnostics only, never an assertion.
    private func visibleIdentifiers(_ app: XCUIApplication) -> [String] {
        (app.buttons.allElementsBoundByIndex + app.staticTexts.allElementsBoundByIndex)
            .map { "[\($0.identifier)] \($0.label)" }
    }

    /// Resolve `identifier` to a BUTTON, falling back to any element.
    ///
    /// The single most confusing failure in building this file: an
    /// `.accessibilityIdentifier` on a SwiftUI `Button` is stamped onto the
    /// button AND everything inside its label, so a
    /// `descendants(matching: .any)…firstMatch` can resolve to an inner
    /// static text. Clicking that text is a no-op — the cron row was
    /// clicked six times in a row with the detail pane never opening, while
    /// the button sat right there. Ask for the button.
    private func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func row(_ app: XCUIApplication, jobID: String) -> XCUIElement {
        control(app, "cron.row.\(jobID)")
    }

    private func card(_ app: XCUIApplication, taskID: String) -> XCUIElement {
        control(app, "kanban.card.\(taskID)")
    }

    /// Containment, not adjacency: the card query is scoped to the column
    /// element, which is the only honest way to assert "this card is in
    /// that column" when both identifiers propagate to sub-elements.
    private func cardIsIn(_ app: XCUIApplication, taskID: String, column: String, timeout: TimeInterval) -> Bool {
        let columnElement = app.descendants(matching: .any)
            .matching(identifier: "kanban.column.\(column)").firstMatch
        return waitUntil("card \(taskID) in column \(column)", timeout: timeout) {
            columnElement.exists
                && columnElement.descendants(matching: .any)
                    .matching(identifier: "kanban.card.\(taskID)").firstMatch.exists
        }
    }

    /// Which board columns currently contain `taskID` — diagnostics for a
    /// failed containment assertion, so the message can say where the card
    /// actually is instead of only where it is not.
    private func columnsContaining(_ app: XCUIApplication, taskID: String) -> [String] {
        KanbanColumnIdentifiers.all.filter { column in
            let element = app.descendants(matching: .any)
                .matching(identifier: "kanban.column.\(column)").firstMatch
            return element.exists
                && element.descendants(matching: .any)
                    .matching(identifier: "kanban.card.\(taskID)").firstMatch.exists
        }
    }

    /// `KanbanBoardColumn.rawValue`s. Duplicated as literals because this
    /// bundle links neither the app nor ScarfCore.
    enum KanbanColumnIdentifiers {
        static let all = ["triage", "scheduled", "upNext", "running", "review", "blocked", "done", "archived"]
    }

    // MARK: - Typing

    /// Click to focus, type, then VERIFY the field holds what was typed —
    /// retrying from empty if it does not.
    ///
    /// Both halves are load-bearing, both learned the hard way:
    ///
    /// - `typeText` on an unfocused macOS field goes to whatever holds
    ///   first responder, silently leaving the field empty.
    /// - Synthesized typing DROPS CHARACTERS when the app is busy. A real
    ///   run typed "UI Gate Job C39BA247" and the field ended up holding
    ///   "UI Gate Job 9BA247" — the journey then failed 30 s later looking
    ///   for a job by a name that was never submitted, which reads like a
    ///   product bug and is not one. So: read the value back, and if it
    ///   disagrees, select-all + delete and type again.
    ///
    /// A field that still refuses after `attempts` fails HERE, where the
    /// message can say what happened.
    private func type(into element: XCUIElement, _ text: String, attempts: Int = 3) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Field \(element.identifier) never appeared.")
        // Named activity, not a comment: when `typeText` fails with
        // "Timed out while synthesizing event" — which is what a busy main
        // thread looks like from the runner — the result bundle otherwise
        // says nothing about WHICH field was being filled.
        XCTContext.runActivity(named: "Type into \(element.identifier)") { _ in
            let app = XCUIApplication()
            // Clicks reach a non-key window; KEYSTROKES do not. Between
            // launch and here the journey spends up to a minute in
            // subprocess calls and waits, and if anything else has taken
            // the keyboard by then, `typeText` fails with "Timed out while
            // synthesizing event" — which reads like a hung app and is
            // really just a window that is not key. Re-activating is cheap
            // and idempotent.
            app.activate()
            waitForForeground(app, timeout: 15)
            for attempt in 1...max(1, attempts) {
                element.click()
                if attempt > 1 {
                    element.typeKey("a", modifierFlags: .command)
                    element.typeKey(.delete, modifierFlags: [])
                }
                // App-level rather than element-level typing. `element
                // .typeText` re-resolves the element and waits for it to
                // settle before every keystroke, and that wait is what
                // failed as "Failed to synthesize event: Timed out while
                // synthesizing event" — an unrecoverable failure that ends
                // the journey. The field already has focus from the click
                // above, so typing at the app is the same keystrokes with
                // none of the per-key element resolution.
                app.typeText(text)
                if (element.value as? String) == text { return }
                print("[journey] \(element.identifier) holds '\(element.value as? String ?? "<nil>")' after attempt \(attempt), wanted '\(text)' — retyping.")
            }
            XCTFail("\(element.identifier) would not hold '\(text)' after \(attempts) attempts; it holds '\(element.value as? String ?? "<nil>")'.")
        }
    }

    /// Type `text`, then return what the field ACTUALLY holds.
    ///
    /// For the one value a journey later looks the record up by. Even with
    /// the retry above, the honest identity of the created record is
    /// whatever was on screen when Save was clicked — asserting on the
    /// string we MEANT to type turns a runner typing artifact into a
    /// 30-second "the app never wrote the job" failure that blames the
    /// app. Cross-checking against the returned value keeps the real
    /// assertion (UI and CLI agree) intact.
    private func fill(_ element: XCUIElement, _ text: String) -> String {
        type(into: element, text)
        let actual = (element.value as? String) ?? ""
        XCTAssertFalse(actual.isEmpty, "\(element.identifier) is empty after typing — nothing would be created.")
        return actual
    }

    // MARK: - Waiting

    /// Poll `condition` until it holds. `XCTNSPredicateExpectation`
    /// evaluates its predicate on a timer, which is what lets it wait on
    /// arbitrary state (a file on disk, CLI output) that posts no KVO
    /// notifications — and is why nothing in this target sleeps.
    @discardableResult
    private func waitUntil(_ description: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: NSObject()
        )
        expectation.expectationDescription = description
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Ground truth: cron/jobs.json

    struct CronJob {
        let id: String
        let name: String
        let enabled: Bool
    }

    /// Decode `<isolatedHome>/cron/jobs.json` — the file Hermes writes and
    /// `CronViewModel` reads. Absent file (never any job) decodes to an
    /// empty list; an unreadable one does too, which is safe here because
    /// every call site asserts on the CONTENT, so a decode failure shows
    /// up as "the job never landed" rather than as a false pass.
    private func cronJobsOnDisk() -> [CronJob] {
        guard let isolatedHome else { return [] }
        let url = URL(fileURLWithPath: isolatedHome)
            .appendingPathComponent("cron/jobs.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = root["jobs"] as? [[String: Any]] else { return [] }
        return jobs.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return CronJob(
                id: id,
                name: entry["name"] as? String ?? "",
                // Absent `enabled` means an older schema that had no
                // pause concept — treat as enabled rather than crashing.
                enabled: entry["enabled"] as? Bool ?? true
            )
        }
    }

    // MARK: - Ground truth: hermes kanban list

    struct KanbanTask {
        let id: String
        let status: String
        let title: String
    }

    /// `hermes kanban list` rows look like
    /// `▶ t_37b40063  ready     (unassigned)   Fixture: wire up the sweep`.
    ///
    /// The plain form is parsed rather than `--json` on purpose: the JSON
    /// object is printed AFTER a first-run gateway advisory, so the plain
    /// output plus a `t_<hex>` match is the sturdier read (VERBS.md).
    private func kanbanTasks() -> [KanbanTask] {
        let output = runHermes(["kanban", "list"]).stdout
        // GOTCHA, measured against v0.21.0: the assignee column is
        // parenthesised ONLY when there is no assignee. An unassigned row
        // reads `t_37b40063  ready     (unassigned)   Fixture: …`, an
        // assigned one `t_a1ddf68e  ready     test-override   Probe Card`.
        // A pattern that required the parentheses silently parsed ZERO
        // rows for every card the app created — Scarf assigns the active
        // profile — and the journey read that as "the create never reached
        // the CLI" while the card was plainly on screen.
        let pattern = try? NSRegularExpression(
            pattern: #"(t_[0-9a-f]+)\s+(\S+)\s+(?:\([^)]*\)|\S+)\s+(.+?)\s*$"#
        )
        return output.split(separator: "\n").compactMap { line in
            let line = String(line)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern?.firstMatch(in: line, range: range),
                  let idRange = Range(match.range(at: 1), in: line),
                  let statusRange = Range(match.range(at: 2), in: line),
                  let titleRange = Range(match.range(at: 3), in: line) else { return nil }
            return KanbanTask(
                id: String(line[idRange]),
                status: String(line[statusRange]).lowercased(),
                title: String(line[titleRange])
            )
        }
    }

    // MARK: - CLI

    /// The line of a `hermes cron list` listing that carries `jobID` AND the
    /// `[paused]` badge, or nil when the job is absent or not badged paused.
    ///
    /// Line-scoped on purpose: the fixture home seeds its own paused cron
    /// jobs, so asking whether the whole listing contains the id and —
    /// somewhere, anywhere — the string `[paused]` would pass on a
    /// neighbour's badge. The CLI prints the pair on one row
    /// (`hermes_cli/cron.py` `_print_banner` + `_STATE_BADGES`), which is
    /// what makes the narrow read both exact and cheap.
    private func pausedBadgeLine(for jobID: String, in listing: String) -> String? {
        listing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first { $0.contains(jobID) && $0.contains("[paused]") }
    }

    /// Run the real `hermes` CLI against THIS TEST'S isolated home.
    ///
    /// `HERMES_HOME` is passed explicitly and is the whole safety story:
    /// without it the CLI reads `~/.hermes` and these "verifications"
    /// would be asserting against the developer's real data.
    @discardableResult
    private func runHermes(_ arguments: [String], timeout: TimeInterval = 30) -> (code: Int32, stdout: String, stderr: String) {
        guard let isolatedHome,
              FileManager.default.isExecutableFile(atPath: Self.hermesBinary) else {
            return (-1, "", "no hermes binary at \(Self.hermesBinary)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.hermesBinary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = isolatedHome
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Charter C10's spirit applied to the test side: every subprocess
        // gets a timeout. A wedged CLI must fail this journey, not hang
        // the whole gate until Xcode's own limit fires with no diagnosis.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        do {
            try process.run()
        } catch {
            watchdog.cancel()
            return (-1, "", "failed to spawn hermes: \(error)")
        }
        // Drain BEFORE waiting for exit: a pipe that fills up blocks the
        // child forever, and `cron list --all` output is not small.
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let timedOut = watchdog.isCancelled == false && process.terminationReason == .uncaughtSignal
        watchdog.cancel()

        return (
            process.terminationStatus,
            stdout,
            timedOut ? stderr + "\n[hermes \(arguments.joined(separator: " ")) was terminated after \(timeout)s]" : stderr
        )
    }

    // MARK: - Fixture

    /// True when the runner was handed a fixture home. Read from the
    /// RUNNER's environment (`TEST_RUNNER_SCARF_UITEST_FIXTURE=…` on the
    /// xcodebuild command line), the same place `makeIsolatedHermesHome`
    /// reads it, so the two can never disagree about which mode this is.
    private var isFixtureRun: Bool {
        let path = ProcessInfo.processInfo.environment[Self.fixtureHomeEnvVar] ?? ""
        guard !path.isEmpty else { return false }
        let marker = (path as NSString).appendingPathComponent(Self.testHomeMarkerFilename)
        return FileManager.default.fileExists(atPath: marker)
    }

}
