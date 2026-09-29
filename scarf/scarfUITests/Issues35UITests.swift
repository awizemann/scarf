//
//  Issues35UITests.swift
//  scarfUITests
//
//  On-screen proof of the four 3.5.0 fixes (plan
//  documents/plans/2026-09-29-open-issues-3.5-fixes-plan.md):
//
//  | test                                              | issue | needs          |
//  |---------------------------------------------------|-------|----------------|
//  | testBranchBadgeMarksOnlyBranchSessions            | #145  | fixture        |
//  | testRetryAndUndoAreAnsweredLocallyAndSendNothing  | #147  | nothing        |
//  | testReopeningACliSessionKeepsTranscriptAndSaysSo  | #146  | fixture + Live |
//  | testLoadedHistoryShowsOneTurnDurationPill         | #148  | fixture + Live |
//  | testTitleRenamesASavedChat                        | #147  | fixture + Live |
//
//  "Live" here means a real `hermes acp` process against the isolated
//  home (clicking a chat row resumes it over ACP) — NO provider turn is
//  ever run, so nothing spends tokens. There is no fake ACP agent in this
//  harness, which is why a LIVE turn's pill (#148's "exactly one pill
//  after a turn with a tool call") is proven on persisted history only;
//  the live stopwatch half is pinned by ScarfCore's TurnDurationTests.
//
//  Seeded rows come from `scripts/ui-fixture/make-ui-fixture.sh`
//  ("seed: 3.5.0 issue sessions"); the ids below are duplicated from it.
//  A missing row is a SKIP naming the fixture command, never a failure.
//
//      FIXTURE="$(scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home")"
//      TEST_RUNNER_SCARF_UITEST_FIXTURE="$FIXTURE" TEST_RUNNER_SCARF_UITEST_LIVE=1 \
//        xcodebuild test … -only-testing:scarfUITests/Issues35UITests
//

import XCTest

final class Issues35UITests: ScarfUITestCase {

    // MARK: - Seeded ids (make-ui-fixture.sh, "seeded ids")

    private static let plain = "ui35-plain-0001"
    private static let branchChild = "ui35-branch-child-0003"
    private static let branchParentTitle = "UI35 Branch Parent"
    private static let resetChild = "ui35-reset-child-0005"
    private static let compressChild = "ui35-compress-child-0007"
    private static let cliTools = "ui35-cli-tools-0008"
    private static let acpTitle = "ui35-acp-title-0009"

    /// The final assistant row of the cli transcript, and the user prompt.
    private static let cliFinalText = "UI35 DONE three files"
    private static let cliPromptText = "UI35 list the files"

    // MARK: - #145 Branch badge

    /// A `/branch` child carries the Branch mark in BOTH the Sessions
    /// list and the chat sidebar; a plain root, a reset child and a
    /// compression continuation do not.
    ///
    /// Both rows are Buttons with their own identifier, which rewrites
    /// the badge's `session.branchBadge` identifier (see the XCUITest
    /// runner-gotchas note), so the mark is read off the row's composed
    /// label: the Sessions row appends `SessionBranchBadge.description`
    /// ("Branch of “Parent”"), the chat row composes its children's
    /// labels, which include the badge's.
    @MainActor
    func testBranchBadgeMarksOnlyBranchSessions() throws {
        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Sessions")
        let branchRow = try requireSeeded(app, "sessions.row.\(Self.branchChild)")
        assertBranchMark(branchRow, expected: true, where_: "Sessions list", id: Self.branchChild, app: app)
        for id in [Self.plain, Self.resetChild] {
            let row = element(app, "sessions.row.\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 10), "sessions.row.\(id) is not listed — the fixture's control rows are missing.")
            assertBranchMark(row, expected: false, where_: "Sessions list", id: id, app: app)
        }
        let compressRow = element(app, "sessions.row.\(Self.compressChild)")
        if compressRow.exists {
            assertBranchMark(compressRow, expected: false, where_: "Sessions list", id: Self.compressChild, app: app)
        }

        try openSection(app, "Chat")
        let chatBranch = try requireSeeded(app, "chat.session.\(Self.branchChild)")
        assertBranchMark(chatBranch, expected: true, where_: "chat sidebar", id: Self.branchChild, app: app)
        for id in [Self.plain, Self.resetChild] {
            let row = element(app, "chat.session.\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 10), "chat.session.\(id) is not listed in the chat sidebar.")
            assertBranchMark(row, expected: false, where_: "chat sidebar", id: id, app: app)
        }
        let chatCompress = element(app, "chat.session.\(Self.compressChild)")
        if chatCompress.exists {
            assertBranchMark(chatCompress, expected: false, where_: "chat sidebar", id: Self.compressChild, app: app)
        }
    }

    private func assertBranchMark(
        _ row: XCUIElement, expected: Bool, where_ surface: String, id: String,
        app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let label = row.label
        // The badge itself, if the identifier survives on this surface.
        let badge = row.descendants(matching: .any).matching(identifier: "session.branchBadge").firstMatch
        let marked = label.contains("Branch of") || badge.exists
        if marked != expected {
            print("[Issues35] \(surface) row \(id) label: \(label)\n\(row.debugDescription)")
            attachScreenshot(app, named: "branch-mark-\(id)", keepAlways: true)
        }
        XCTAssertEqual(marked, expected,
                       "\(surface) row \(id) \(expected ? "lacks" : "carries") the Branch mark. Label: \"\(label)\"",
                       file: file, line: line)
        if expected {
            XCTAssertTrue(label.contains(Self.branchParentTitle) || badge.label.contains(Self.branchParentTitle),
                          "\(surface) Branch mark for \(id) does not name its parent \"\(Self.branchParentTitle)\". Label: \"\(label)\"",
                          file: file, line: line)
        }
    }

    // MARK: - #147 /retry and /undo

    /// On a fresh chat (no session, no ACP process) `/retry` and `/undo`
    /// answer with the "use the Hermes CLI" note and never reach the
    /// agent: no user bubble echoes them, and no session is started.
    /// Before the fix both went out as a prompt (auto-starting ACP).
    @MainActor
    func testRetryAndUndoAreAnsweredLocallyAndSendNothing() throws {
        let app = launchExpanded()
        defer { gracefulQuit(app) }
        try openSection(app, "Chat")

        for command in ["/retry", "/undo"] {
            try send(command, in: app)
            let note = app.windows.descendants(matching: .staticText)
                .matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", command, "Use the Hermes CLI"))
                .firstMatch
            if !note.waitForExistence(timeout: 4) {
                attachScreenshot(app, named: "no-cli-note-\(command.dropFirst())", keepAlways: true)
                print("[Issues35] AX tree:\n\(app.windows.firstMatch.debugDescription)")
            }
            XCTAssertTrue(note.exists, "Sending \(command) showed no \"Use the Hermes CLI\" note.")
            let echoed = app.windows.descendants(matching: .group)
                .matching(NSPredicate(format: "label == 'You'"))
                .descendants(matching: .staticText)
                .matching(NSPredicate(format: "value == %@", command))
                .firstMatch
            XCTAssertFalse(echoed.exists, "\(command) was echoed as a user bubble — it was sent to the agent.")
        }
        // Nothing reached ACP: the header never left "no session".
        let anyUser = app.windows.descendants(matching: .group)
            .matching(NSPredicate(format: "label == 'You'")).firstMatch
        XCTAssertFalse(anyUser.exists, "A user bubble appeared — something was sent to the agent.")
    }

    // MARK: - #146 honest resume of a cli session

    /// Opening a `source = cli` session from the chat sidebar keeps its
    /// transcript on screen and shows the persistent continuity notice
    /// ("This session started in cli. …"), and the pane is NOT bound to
    /// the old id (it continued as a new session instead of claiming a
    /// resume).
    @MainActor
    func testReopeningACliSessionKeepsTranscriptAndSaysSo() throws {
        try requireLive()
        let app = launchExpanded()
        defer { gracefulQuit(app) }
        try openSection(app, "Chat")

        let row = try requireSeeded(app, "chat.session.\(Self.cliTools)")
        let noticeRow = notice(app)
        guard clickUntil(row, appears: noticeRow, named: "the continuity notice", in: app) else {
            attachScreenshot(app, named: "no-continuity-notice", keepAlways: true)
            print("[Issues35] AX tree:\n\(app.windows.firstMatch.debugDescription)")
            let banner = element(app, "error.banner")
            XCTFail("Opening the cli session never showed the continuity notice. Error banner: \(banner.exists ? banner.label : "<none>")")
            return
        }
        XCTAssertTrue(noticeRow.label.contains("This session started in cli"),
                      "The notice does not name the session's source (cli). It reads: \(noticeRow.label)")
        XCTAssertTrue(staticText(app, containing: Self.cliFinalText).waitForExistence(timeout: 10),
                      "The old transcript (\"\(Self.cliFinalText)\") is not on screen next to the notice.")
        XCTAssertTrue(staticText(app, containing: Self.cliPromptText).exists,
                      "The old user prompt (\"\(Self.cliPromptText)\") is not on screen.")
        XCTAssertNotEqual(row.value as? String, "active",
                          "The pane is bound to the cli session's own id — it claimed to resume a session Hermes cannot reopen.")
        // Persistent: still there after the hint window (4 s) of any
        // transient note would have closed — polled, not slept.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: noticeRow)
        XCTAssertNotEqual(XCTWaiter().wait(for: [gone], timeout: 6), .completed,
                          "The continuity notice disappeared — it must stay while the chat is on that session.")
    }

    // MARK: - #148 history-derived turn duration

    /// A persisted turn with a tool call (user → assistant(tool_calls) →
    /// tool → assistant) renders exactly ONE duration pill, on the turn's
    /// LAST assistant bubble, derived from the row timestamps (7 s apart
    /// in the fixture). Reopening the session still shows it. Before the
    /// fix loaded history carried no pill at all.
    @MainActor
    func testLoadedHistoryShowsOneTurnDurationPill() throws {
        try requireLive()
        let app = launchExpanded()
        defer { gracefulQuit(app) }
        try openSection(app, "Chat")

        let row = try requireSeeded(app, "chat.session.\(Self.cliTools)")
        let other = try requireSeeded(app, "chat.session.\(Self.plain)")

        try openTranscript(row, app)
        assertOnePillOnFinalBubble(app, after: "opening the session")

        // Away and back: the pill is history-derived, so it survives.
        let final = staticText(app, containing: Self.cliFinalText)
        var left = false
        for _ in 1...3 where !left {
            ensureFrontmost(app)
            other.click()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: final)
            left = XCTWaiter().wait(for: [gone], timeout: 15) == .completed
        }
        XCTAssertTrue(left, "Switching to \(Self.plain) never replaced the cli transcript.")
        try openTranscript(row, app)
        assertOnePillOnFinalBubble(app, after: "reopening the session")
    }

    private func openTranscript(_ row: XCUIElement, _ app: XCUIApplication) throws {
        let final = staticText(app, containing: Self.cliFinalText)
        guard clickUntil(row, appears: final, named: "the cli transcript", in: app) else {
            attachScreenshot(app, named: "no-cli-transcript", keepAlways: true)
            throw NSError(domain: "Issues35UITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Clicking chat.session.\(Self.cliTools) never showed its transcript."])
        }
        // The fallback new session settles after the history paints.
        _ = notice(app).waitForExistence(timeout: 20)
    }

    private func assertOnePillOnFinalBubble(_ app: XCUIApplication, after context: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let finalBubble = app.windows.descendants(matching: .group)
            .matching(NSPredicate(format: "label == 'Assistant'"))
            .containing(NSPredicate(format: "value CONTAINS %@", Self.cliFinalText))
            .firstMatch
        let pillOnFinal = finalBubble.descendants(matching: .any).matching(identifier: "chat.turnDuration").firstMatch
        if !pillOnFinal.waitForExistence(timeout: 10) {
            attachScreenshot(app, named: "no-duration-pill", keepAlways: true)
            print("[Issues35] AX tree:\n\(app.windows.firstMatch.debugDescription)")
        }
        XCTAssertTrue(pillOnFinal.exists, "No duration pill on the turn's last assistant bubble after \(context).",
                      file: file, line: line)
        XCTAssertEqual(pillOnFinal.exists ? (pillOnFinal.value as? String) : nil, "7.0s",
                       "The pill should read the user→last-assistant gap (7 s in the fixture) after \(context).",
                       file: file, line: line)
        let pills = app.windows.descendants(matching: .any).matching(identifier: "chat.turnDuration").count
        XCTAssertEqual(pills, 1, "Expected exactly one duration pill for the one turn after \(context); found \(pills).",
                       file: file, line: line)
    }

    // MARK: - #147 /title

    /// `/title <name>` on a saved (restored) ACP chat renames it through
    /// `hermes sessions rename`: the sidebar row's title changes. Before
    /// the fix `/title` went to the model as text and nothing was renamed.
    @MainActor
    func testTitleRenamesASavedChat() throws {
        try requireLive()
        let app = launchExpanded()
        defer { gracefulQuit(app) }
        try openSection(app, "Chat")

        let row = try requireSeeded(app, "chat.session.\(Self.acpTitle)")
        let bound = app.windows.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == 'active'", "chat.session.\(Self.acpTitle)"))
            .firstMatch
        guard clickUntil(row, appears: bound, named: "the ACP chat to bind", in: app) else {
            attachScreenshot(app, named: "acp-chat-never-bound", keepAlways: true)
            throw XCTSkip("Hermes's ACP did not restore \(Self.acpTitle) (session/load refused), so there is no saved chat to rename.")
        }
        let newTitle = "UI35 Renamed"
        try send("/title \(newTitle)", in: app)
        let renamed = waitUntil(timeout: 20, describing: "the chat row to show the new title") {
            row.label.contains(newTitle)
        }
        if !renamed {
            attachScreenshot(app, named: "title-not-renamed", keepAlways: true)
            print("[Issues35] row label: \(row.label)\n\(app.windows.firstMatch.debugDescription)")
        }
        XCTAssertTrue(renamed, "After /title \(newTitle) the chat row still reads \"\(row.label)\".")
        let echoed = app.windows.descendants(matching: .group)
            .matching(NSPredicate(format: "label == 'You'"))
            .descendants(matching: .staticText)
            .matching(NSPredicate(format: "value BEGINSWITH '/title'"))
            .firstMatch
        XCTAssertFalse(echoed.exists, "/title was sent to the agent as a prompt.")
    }

    // MARK: - Helpers

    private func send(_ text: String, in app: XCUIApplication) throws {
        let input = element(app, "chat.composer.input")
        XCTAssertTrue(input.waitForExistence(timeout: 25), "No chat.composer.input.")
        setText(text, in: input, of: app)
        let sendButton = element(app, "chat.composer.send")
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10), "No chat.composer.send.")
        for attempt in 1...3 {
            ensureFrontmost(app)
            if sendButton.exists && sendButton.isEnabled { sendButton.click() }
            if waitUntil(timeout: 5, describing: "the composer to clear", { ((input.value as? String) ?? "") != text }) { return }
            print("[Issues35] send attempt \(attempt)/3 left \(text) in the composer.")
        }
        XCTFail("Clicking send never cleared \(text) from the composer.")
    }

    /// The #146 continuity notice row (`ResumeContinuityNoticeRow`). Its
    /// combined text was NOT reachable by label/value predicates, so the
    /// row carries an identifier; the wording is asserted separately.
    private func notice(_ app: XCUIApplication) -> XCUIElement {
        app.windows.descendants(matching: .any)
            .matching(identifier: "chat.resumeContinuityNotice").firstMatch
    }

    private func staticText(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.windows.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    private func requireSeeded(_ app: XCUIApplication, _ identifier: String) throws -> XCUIElement {
        let row = element(app, identifier)
        guard row.waitForExistence(timeout: 25) else {
            throw XCTSkip(
                "No \(identifier) on screen. This test needs the seeded fixture home: "
                + "FIXTURE=\"$(scripts/ui-fixture/make-ui-fixture.sh \"$(mktemp -d)/fixture-home\")\" "
                + "TEST_RUNNER_SCARF_UITEST_FIXTURE=\"$FIXTURE\" xcodebuild test …"
            )
        }
        return row
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.windows.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launchExpanded() -> XCUIApplication {
        let app = makeApp(extraLaunchArguments: SectionSweepUITests.expandedSidebarLaunchArguments)
        launchAndSurface(app)
        assertAllSidebarSectionsExpanded(app)
        return app
    }

    private func ensureFrontmost(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        if app.state != .runningForeground {
            app.activate()
            waitForForeground(app, timeout: 10)
        }
    }

    private func openSection(_ app: XCUIApplication, _ section: String) throws {
        ensureFrontmost(app)
        let row = element(app, "sidebar.section.\(section)")
        guard row.waitForExistence(timeout: 20) else {
            XCTFail("sidebar.section.\(section) is missing.")
            return
        }
        let root = element(app, "\(section).root")
        for _ in 1...3 {
            ensureFrontmost(app)
            row.click()
            if root.waitForExistence(timeout: 15) { return }
        }
        XCTFail("\(section).root never appeared.")
    }

    private func waitUntil(timeout: TimeInterval, describing what: String, _ condition: @escaping () -> Bool) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = "Waiting for \(what)"
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
