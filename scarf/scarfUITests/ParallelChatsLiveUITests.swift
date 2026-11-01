//
//  ParallelChatsLiveUITests.swift
//  scarfUITests
//
//  Parallel chats P3: a window's chats, against a REAL `hermes acp` and a real
//  provider. Unit tests pin the state machines with fake clients; only this
//  proves that a background chat really keeps talking to Hermes.
//
//  Turns are made long on purpose by asking the model to run `sleep N` in its
//  terminal tool, so "both replying at once" is a fact about Hermes rather
//  than a race the test happens to win. A row's ACTIVE value names the chat on
//  screen, which is how a test learns a new chat's session id (Hermes titles a
//  chat on its own, so a row can't be found by its text). A row is there as
//  soon as a prompt has gone out, on both tags; below v0.22 Scarf supplies it
//  until Hermes has stored the session (`ChatViewModel.sessionsForList`).
//
//  Evidence beyond the UI: the state.db of the Hermes home in use, read-only
//  (charter C3), and, in the VM, the count of `hermes acp` processes that
//  scripts/ui-gate-vm.sh writes for the sandboxed runner (it can't run ps).
//
//  The two budget journeys reach a remote host over real SSH: the guest's own
//  sshd on 127.0.0.1, set up by scripts/ui-gate-vm.sh for the Live plan. Without
//  that they skip, so they never touch a developer's server list.
//  With the gate's --real-remote the same journeys reach a real server instead:
//  SCARF_UITEST_LOOPBACK_HOME is then a local read-only copy of that host's
//  state.db, and the process list includes that host's own `hermes acp`s.
//

import XCTest
import SQLite3

final class ParallelChatsLiveUITests: ScarfUITestCase {

    private static let replyTimeout: TimeInterval = 180
    private static let rowIdPrefix = "chat.session."

    /// Written by make-ui-fixture.sh once its real chats have answered.
    private static let providerVerifiedMarker = ".scarf-provider-verified"

    // The real home must stay untouched (same tripwire as ChatJourneyUITests).
    private var realStateDBModified: Date?
    private static var realStateDBPath: String {
        ((realHome as NSString).appendingPathComponent(".hermes") as NSString)
            .appendingPathComponent("state.db")
    }
    private static func modificationDate(ofFileAt path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The Hermes home the app under test is talking to.
    private var hermesHome: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Several chats, each a real model turn around a sleep. Capped by the
        // gate's -maximum-test-execution-time-allowance.
        executionTimeAllowance = 600
        hermesHome = isolatedHome
        realStateDBModified = Self.modificationDate(ofFileAt: Self.realStateDBPath)
    }

    override func tearDownWithError() throws {
        let after = Self.modificationDate(ofFileAt: Self.realStateDBPath)
        XCTAssertEqual(after, realStateDBModified, "\(Self.realStateDBPath) was written: the isolated home leaked.")
        try super.tearDownWithError()
    }

    // MARK: - 1. Two chats replying at once

    /// Two chats reply at the same time; moving between them neither stops
    /// either nor mixes their replies.
    @MainActor
    func testTwoChatsReplyAtOnceAndKeepTheirOwnReplies() throws {
        try requireLiveProvider()
        let app = launchLocal()
        try openChat(app)

        let (idA, tokenA) = sendLongTurn(app, 60, "ALPHA", knownIds: [])
        requireRow(app, idA, showsReplying: true, "after its prompt was sent")

        openNewChat(app, leaving: idA)
        XCTAssertFalse(bubbleText(app, "You", tokenA).exists, "The new chat shows the first chat's prompt.")
        let (idB, tokenB) = sendLongTurn(app, 60, "BRAVO", knownIds: [idA])

        // Both at once: this is the behaviour. Opening a chat used to stop the
        // one before it.
        let both = waitUntil(timeout: 60, "both rows to read Replying") {
            self.rowIsReplying(app, idA) && self.rowIsReplying(app, idB)
        }
        failWithEvidence(both, app, "The two chats were never both Replying: A=\(rowLabel(app, idA)) B=\(rowLabel(app, idB))")

        // Switching, both ways, while both run.
        select(app, idA)
        XCTAssertTrue(bubbleText(app, "You", tokenA).waitForExistence(timeout: 15), "Chat A doesn't show its own prompt.")
        XCTAssertFalse(bubbleText(app, "You", tokenB).exists, "Chat A shows chat B's prompt.")
        XCTAssertTrue(element(app, "chat.composer.stop").waitForExistence(timeout: 10), "Chat A isn't working after being switched back to.")
        XCTAssertTrue(rowIsReplying(app, idB), "Chat B stopped when chat A was focused: \(rowLabel(app, idB))")

        select(app, idB)
        XCTAssertTrue(bubbleText(app, "You", tokenB).waitForExistence(timeout: 15), "Chat B doesn't show its own prompt.")
        XCTAssertFalse(bubbleText(app, "You", tokenA).exists, "Chat B shows chat A's prompt.")
        XCTAssertTrue(element(app, "chat.composer.stop").waitForExistence(timeout: 10), "Chat B isn't working after being switched back to.")
        XCTAssertTrue(rowIsReplying(app, idA), "Chat A stopped when chat B was focused: \(rowLabel(app, idA))")

        // Each finishes with its own reply, seen by going to it.
        failWithEvidence(awaitBubble(app, "Assistant", tokenB), app, "Chat B never got its reply.")
        select(app, idA)
        failWithEvidence(awaitBubble(app, "Assistant", tokenA), app, "Chat A never got its reply: it stopped, or its reply was lost.")
        XCTAssertFalse(bubbleText(app, "Assistant", tokenB).exists, "Chat A shows chat B's reply.")
        XCTAssertFalse(bubbleText(app, "You", tokenB).exists, "Chat A shows chat B's prompt.")
        select(app, idB)
        XCTAssertTrue(bubbleText(app, "Assistant", tokenB).waitForExistence(timeout: 15), "Chat B lost its reply.")
        XCTAssertFalse(bubbleText(app, "Assistant", tokenA).exists, "Chat B shows chat A's reply.")
        XCTAssertFalse(transcriptMentionsCancel(app), "Chat B says its turn was cancelled.")

        // Hermes agrees: each session holds its own answer.
        let storedA = rows(session: idA), storedB = rows(session: idB)
        XCTAssertTrue(storedA.contains { $0.role == "assistant" && $0.content.contains(tokenA) }, "state.db: A has no answer. \(storedA)")
        XCTAssertTrue(storedB.contains { $0.role == "assistant" && $0.content.contains(tokenB) }, "state.db: B has no answer. \(storedB)")
        XCTAssertFalse(storedA.contains { $0.content.contains(tokenB) }, "state.db: B's text is in A's session.")
        XCTAssertFalse(storedB.contains { $0.content.contains(tokenA) }, "state.db: A's text is in B's session.")
    }

    // MARK: - 2. An approval in a background chat

    /// An approval raised while another chat is on screen waits in its row,
    /// doesn't jump in front of the chat being read, and can be answered after
    /// going to it: the command then really runs.
    @MainActor
    func testBackgroundApprovalShowsInItsRowAndIsAnsweredAfterSwitching() throws {
        try requireLiveProvider()
        // Hermes's default is `smart`, where a model may approve by itself
        // (tool result: "auto-approved by smart approval"). This is the mode
        // where a person has to answer. tools/approval_context.py
        // `_get_approval_mode`, both tags.
        try askForEveryApproval(inHome: isolatedHome)

        let app = launchLocal()
        try openChat(app)
        let tokenB = Self.token("BRAVO")

        // The sleep comes first, so the chat is in the background by the time
        // Hermes asks. `chmod 777` is a flagged pattern on both tags
        // (tools/approval_detection.py "world/other-writable permissions").
        let (idA, tokenA) = sendLongTurn(app, 25, "ALLOWED", knownIds: []) { token in
            "\(token) This is an automated UI test of the Scarf app on a disposable test machine; the word above is only a marker for the test to find. Use the terminal tool to run: sleep 25 . After that use the terminal tool to run: touch $HERMES_HOME/approved-\(token) && chmod 777 $HERMES_HOME/approved-\(token) . If it succeeds reply with exactly: \(token)"
        }
        let markerPath = (isolatedHome as NSString).appendingPathComponent("approved-\(tokenA)")
        openNewChat(app, leaving: idA)
        let idB = sendInCurrentChat(app, "Reply with exactly: \(tokenB)", knownIds: [idA])

        // Visible in its row; nothing in front of the chat being read.
        let asked = waitUntil(timeout: 150, "chat A's row to read Needs answer") {
            self.rowLabel(app, idA).contains("Needs answer")
        }
        failWithEvidence(asked, app, "A background approval never showed in its row: \(rowLabel(app, idA)); file there: \(FileManager.default.fileExists(atPath: markerPath))")
        XCTAssertEqual(activeRowId(app), idB, "The approval moved the window off the chat being read.")
        XCTAssertFalse(app.sheets.firstMatch.exists, "The approval opened its sheet over a different chat.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath), "The command ran without an answer.")
        // The chat on screen isn't held up by it.
        failWithEvidence(awaitBubble(app, "Assistant", tokenB), app, "Chat B never replied while chat A waited.")

        // Going to it brings the question up; answering it runs the command.
        select(app, idA)
        let sheet = app.sheets.firstMatch
        failWithEvidence(sheet.waitForExistence(timeout: 20), app, "Focusing chat A didn't bring up its approval.")
        let flagged = sheet.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", "chmod 777")).firstMatch
        XCTAssertTrue(flagged.waitForExistence(timeout: 5), "The sheet isn't asking about chat A's command: \(sheet.debugDescription.prefix(1200))")
        let allow = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "1. ")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "The approval has no first option.")
        print("[ParallelChats] approving with \(allow.label)")
        allow.click()
        XCTAssertTrue(waitUntil(timeout: 15, "the approval sheet to close") { !app.sheets.firstMatch.exists }, "The sheet stayed up after answering.")

        failWithEvidence(awaitBubble(app, "Assistant", tokenA), app, "Chat A never finished after the approval. state.db: \(rows(session: idA).map(\.description)); full reply: \(rows(session: idA).last?.content ?? "")")
        XCTAssertFalse(rowLabel(app, idA).contains("Needs answer"), "The row still asks after being answered: \(rowLabel(app, idA))")
        let attributes = try FileManager.default.attributesOfItem(atPath: markerPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o777, "The approved command didn't run.")
    }

    // MARK: - 3. Deleting a background chat that is working

    /// Deleting a working background chat stops that one chat; the one on
    /// screen keeps replying.
    @MainActor
    func testDeletingAWorkingBackgroundChatStopsOnlyThatChat() throws {
        try requireLiveProvider()
        let app = launchLocal()
        try openChat(app)

        let (idA, _) = sendLongTurn(app, 75, "DOOMED", knownIds: [])
        openNewChat(app, leaving: idA)
        let (idB, tokenB) = sendLongTurn(app, 120, "BRAVO", knownIds: [idA])
        let bothSent = Date()
        XCTAssertTrue(waitUntil(timeout: 60, "both rows to read Replying") {
            self.rowIsReplying(app, idA) && self.rowIsReplying(app, idB)
        }, "Both chats should be replying before the delete.")
        assertACPProcessesBecome(2, "with two chats running")

        let row = element(app, Self.rowIdPrefix + idA)
        row.rightClick()
        let delete = app.menuItems["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "The row has no Delete… item.")
        delete.click()
        let confirm = dialogButton(app, "Delete")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete didn't ask first.")
        confirm.click()

        // That chat: gone from the list, from Hermes, and its process stopped.
        failWithEvidence(waitUntil(timeout: 45, "the deleted row to go") { !row.exists }, app, "The deleted chat's row is still listed: \(rowLabel(app, idA)); in state.db: \(sessionExists(idA)), \(rows(session: idA)).")
        XCTAssertTrue(waitUntil(timeout: 30, "Hermes to drop the session") { self.rows(session: idA).isEmpty && !self.sessionExists(idA) },
                      "state.db still holds the deleted session.")
        assertACPProcessesBecome(1, "after deleting one of two running chats")

        // The other: still on screen, still working, and it finishes.
        XCTAssertEqual(activeRowId(app), idB, "Deleting a background chat moved the window off the chat on screen.")
        XCTAssertTrue(rowIsReplying(app, idB), "The other chat stopped: \(rowLabel(app, idB))")
        XCTAssertTrue(element(app, "chat.composer.stop").exists, "The other chat's Stop control is gone.")
        failWithEvidence(awaitBubble(app, "Assistant", tokenB), app, "The other chat never finished its reply.")
        XCTAssertFalse(transcriptMentionsCancel(app), "The other chat says its turn was cancelled.")

        // B's turn finishing reloads the list, and A's 75-second sleep is long
        // over by now: had A only been hidden, its session would be back with
        // its answer in it.
        XCTAssertGreaterThan(Date().timeIntervalSince(bothSent), 100, "Chat A's turn could still be running; this proves nothing.")
        let stayedGone = !waitUntil(timeout: 8, "the deleted row to come back") { row.exists || self.sessionExists(idA) }
        XCTAssertTrue(stayedGone, "The deleted chat came back: \(rowLabel(app, idA)); in state.db: \(sessionExists(idA)).")
        XCTAssertTrue(rows(session: idA).isEmpty, "The stopped chat went on writing to its deleted session.")
    }

    // MARK: - 4. Closing a window with chats running

    /// ⌘W asks when chats are working. Cancel keeps the window and the chats;
    /// Close Anyway closes the window and stops what was still running.
    @MainActor
    func testClosingAWindowWithRunningChatsAsksFirst() throws {
        try requireLiveProvider()
        let app = launchLocal()
        try openChat(app)
        let longSleep = 90

        let (idA, tokenA) = sendLongTurn(app, longSleep, "LONGER", knownIds: [])
        let sentA = Date()
        openNewChat(app, leaving: idA)
        let (idB, tokenB) = sendLongTurn(app, 30, "BRAVO", knownIds: [idA])
        XCTAssertTrue(waitUntil(timeout: 60, "both rows to read Replying") {
            self.rowIsReplying(app, idA) && self.rowIsReplying(app, idB)
        }, "Both chats should be replying before the close.")

        // Asks, naming the count.
        app.typeKey("w", modifierFlags: .command)
        var title = staticText(app.sheets.firstMatch, containing: "2 chats are still replying")
        failWithEvidence(title.waitForExistence(timeout: 15), app, "⌘W with two chats replying didn't ask: \(app.sheets.firstMatch.debugDescription.prefix(800))")

        // Cancel: the window stays and nothing stopped.
        let cancel = dialogButton(app, "Cancel")
        XCTAssertTrue(cancel.exists, "The confirm has no Cancel.")
        cancel.click()
        XCTAssertTrue(waitUntil(timeout: 10, "the confirm to go") { !app.sheets.firstMatch.exists }, "The confirm stayed up after Cancel.")
        XCTAssertEqual(app.windows.count, 1, "Cancel didn't keep the window.")
        XCTAssertTrue(rowIsReplying(app, idA), "Cancel stopped chat A: \(rowLabel(app, idA))")
        XCTAssertTrue(rowIsReplying(app, idB), "Cancel stopped chat B: \(rowLabel(app, idB))")
        assertACPProcessesAreExactly(2, "after Cancel")
        failWithEvidence(awaitBubble(app, "Assistant", tokenB), app, "Chat B didn't finish after Cancel.")
        XCTAssertFalse(transcriptMentionsCancel(app), "Chat B says its turn was cancelled.")

        // Only chat A works now, and the question counts what's left.
        XCTAssertTrue(waitUntil(timeout: 30, "chat B to go idle") { !self.rowIsReplying(app, idB) }, "Chat B still reads Replying.")
        XCTAssertTrue(rowIsReplying(app, idA), "Chat A stopped along the way: \(rowLabel(app, idA))")
        app.typeKey("w", modifierFlags: .command)
        title = staticText(app.sheets.firstMatch, containing: "1 chat is still replying")
        failWithEvidence(title.waitForExistence(timeout: 15), app, "The second ⌘W didn't ask about the one chat left: \(app.sheets.firstMatch.debugDescription.prefix(800))")

        // Confirm: the window closes and its chats stop.
        let closeAnyway = dialogButton(app, "Close Anyway")
        XCTAssertTrue(closeAnyway.exists, "The confirm has no Close Anyway.")
        closeAnyway.click()
        XCTAssertTrue(waitUntil(timeout: 20, "the window to close") { app.windows.count == 0 }, "Close Anyway left \(app.windows.count) window(s).")
        assertACPProcessesBecome(0, "after closing the window")
        // Wait out the sleep and a model turn: chat A's answer must never come.
        // Gateway-backed Hermes runs the turn outside `hermes acp`, so a
        // process gone doesn't by itself mean the turn stopped.
        let answerBy = sentA.addingTimeInterval(TimeInterval(longSleep) + 30)
        let answered = waitUntil(timeout: max(1, answerBy.timeIntervalSinceNow), "chat A's answer not to come") {
            self.rows(session: idA).contains { $0.role == "assistant" && $0.content.contains(tokenA) }
        }
        XCTAssertFalse(answered, "Chat A finished its reply after its window closed: it was left running unseen.")
    }

    // MARK: - 5. A remote host at the live-chat budget

    /// Four working chats on one remote host fill its budget. A fifth asks:
    /// Wait opens nothing; stopping one opens the new chat and the other three
    /// keep working.
    @MainActor
    func testRemoteHostFullOfWorkingChatsAsksBeforeOpeningAnother() throws {
        try requireLiveProvider()
        let app = try launchLoopback()
        try openChat(app)

        var ids: [String] = []
        var tokens: [String] = []
        for index in 0..<4 {
            if let last = ids.last { openNewChat(app, leaving: last) }
            let (id, token) = sendLongTurn(app, 240, "WORK\(index)", knownIds: ids)
            ids.append(id)
            tokens.append(token)
        }
        let allFour = waitUntil(timeout: 120, "all four rows to read Replying") {
            ids.allSatisfy { self.rowIsReplying(app, $0) }
        }
        failWithEvidence(allFour, app, "Four chats were never all Replying: \(ids.map { rowLabel(app, $0) })")
        assertACPProcessesBecome(4, "with four working chats", overSSH: true)

        // The fifth asks.
        let question = staticText(app.sheets.firstMatch, containing: "Every live chat on")
        failWithEvidence(clickUntil(newChatButton(app), appears: question, named: "the budget question", in: app), app, "A fifth chat on a host with four working didn't ask.")
        // Long texts are truncated in the accessibility tree, so the limit is
        // read off the Stop buttons below and the message by its start only.
        XCTAssertTrue(staticText(app.sheets.firstMatch, containing: "Scarf keeps up to").exists, "The dialog doesn't explain the budget.")
        let stops = app.sheets.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop"))
        failWithEvidence(stops.count == 4, app, "The dialog should offer to stop each of the four: \(app.sheets.firstMatch.debugDescription.prefix(2500))")

        // Wait: nothing opens, nothing stops.
        dialogButton(app, "Wait").click()
        XCTAssertTrue(waitUntil(timeout: 10, "the dialog to go") { !app.sheets.firstMatch.exists }, "The dialog stayed up after Wait.")
        XCTAssertEqual(activeRowId(app), ids[3], "Wait moved the window to another chat.")
        XCTAssertTrue(ids.allSatisfy { rowIsReplying(app, $0) }, "Wait stopped a chat: \(ids.map { rowLabel(app, $0) })")
        assertACPProcessesAreExactly(4, "after Wait", overSSH: true)

        // Stop one: the new chat opens, on the slot it freed.
        failWithEvidence(clickUntil(newChatButton(app), appears: question, named: "the budget question", in: app), app, "The second try didn't ask.")
        let stopOne = app.sheets.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop")).firstMatch
        print("[ParallelChats] budget dialog: \(stopOne.label)")
        stopOne.click()
        let fifthToken = Self.token("FIFTH")
        requireNewChatWorks(app, token: fifthToken, leaving: ids, lastPromptShown: tokens[3])
        let stillWorking = ids.filter { rowIsReplying(app, $0) }
        XCTAssertEqual(stillWorking.count, 3, "Exactly one chat should have stopped: \(ids.map { rowLabel(app, $0) })")
        assertACPProcessesBecome(4, "after stopping one and opening another", overSSH: true)
    }

    /// Deleting a working chat over SSH: only that chat stops, on the host's
    /// own session store.
    @MainActor
    func testDeletingAWorkingChatOnARemoteHostStopsOnlyThatChat() throws {
        try requireLiveProvider()
        let app = try launchLoopback()
        try openChat(app)

        let (idA, _) = sendLongTurn(app, 120, "DOOMED", knownIds: [])
        openNewChat(app, leaving: idA)
        let (idB, tokenB) = sendLongTurn(app, 45, "BRAVO", knownIds: [idA])
        XCTAssertTrue(waitUntil(timeout: 60, "both rows to read Replying") {
            self.rowIsReplying(app, idA) && self.rowIsReplying(app, idB)
        }, "Both chats should be replying before the delete.")
        assertACPProcessesBecome(2, "with two chats running", overSSH: true)
        // On a real server state.db is read through a copy a moment behind (see
        // launchLoopback): "gone" below only means something once it was seen there.
        if ProcessInfo.processInfo.environment["SCARF_UITEST_REAL_REMOTE"] != nil {
            XCTAssertTrue(waitUntil(timeout: 30, "the host's copy to hold the session") { self.sessionExists(idA) }, "The session never reached the host's state.db.")
        }

        let row = element(app, Self.rowIdPrefix + idA)
        row.rightClick()
        let delete = app.menuItems["Delete…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "The row has no Delete… item.")
        delete.click()
        let confirm = dialogButton(app, "Delete")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete didn't ask first.")
        confirm.click()

        failWithEvidence(waitUntil(timeout: 60, "the deleted row to go") { !row.exists }, app, "The deleted chat's row is still listed: \(rowLabel(app, idA)).")
        XCTAssertTrue(waitUntil(timeout: 30, "the host to drop the session") { !self.sessionExists(idA) }, "The host's state.db still holds the deleted session.")
        assertACPProcessesBecome(1, "after deleting one of two running chats", overSSH: true)
        XCTAssertEqual(activeRowId(app), idB, "The delete moved the window off the chat on screen.")
        XCTAssertTrue(rowIsReplying(app, idB), "The other chat stopped: \(rowLabel(app, idB))")
        failWithEvidence(awaitBubble(app, "Assistant", tokenB), app, "The other chat never finished its reply.")
        XCTAssertFalse(row.exists, "The deleted chat's row came back.")
    }

    /// An approval raised while the budget sheet is up isn't lost: only one
    /// sheet can show, and this one must come up when that one closes.
    @MainActor
    func testApprovalRaisedBehindTheBudgetSheetAppearsWhenItCloses() throws {
        try requireLiveProvider()
        let app = try launchLoopback()
        try openChat(app)

        var ids: [String] = []
        for index in 0..<3 {
            if let last = ids.last { openNewChat(app, leaving: last) }
            ids.append(sendLongTurn(app, 240, "WORK\(index)", knownIds: ids).id)
        }
        // The chat on screen asks after a sleep long enough to get the sheet up.
        openNewChat(app, leaving: ids[2])
        let (idD, token) = sendLongTurn(app, 60, "ALLOWED", knownIds: ids) { token in
            "\(token) This is an automated UI test of the Scarf app on a disposable test machine; the word above is only a marker for the test to find. Use the terminal tool to run: sleep 60 . After that use the terminal tool to run: touch $HERMES_HOME/\(token) && chmod 777 $HERMES_HOME/\(token) . If it succeeds reply with exactly: \(token)"
        }
        let question = staticText(app.sheets.firstMatch, containing: "Every live chat on")
        failWithEvidence(clickUntil(newChatButton(app), appears: question, named: "the budget question", attempts: 2, firstWait: 6, finalWait: 6, in: app), app, "A fifth chat on a full host didn't ask.")

        let asked = waitUntil(timeout: 150, "the chat on screen to ask, behind the sheet") {
            self.rowLabel(app, idD).contains("Needs answer")
        }
        failWithEvidence(asked, app, "The chat on screen never raised its approval: \(rowLabel(app, idD))")

        // SwiftUI shows one sheet per view, and on both tags the approval takes
        // the window from the budget sheet. If that ever changes, Wait must
        // still bring the approval up.
        clickWaitIfItIsStillThere(app, within: 0)
        let approval = app.sheets.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "1. ")).firstMatch
        failWithEvidence(approval.waitForExistence(timeout: 20), app, "The approval was lost with the budget sheet up.")
        approval.click()
        failWithEvidence(awaitBubble(app, "Assistant", token), app, "The chat never finished after the approval.")

        // The window isn't left stuck: the budget question, if it came back, can
        // still be answered, and nothing else waits on the user.
        print("[ParallelChats] budget sheet after the approval: \(question.exists)")
        clickWaitIfItIsStillThere(app, within: 5)
        XCTAssertTrue(waitUntil(timeout: 10, "no sheet left") { !app.sheets.firstMatch.exists }, "A sheet stayed up.")
        XCTAssertEqual(activeRowId(app), idD, "The window left the chat it was on.")
    }

    /// With four idle chats on a remote host a fifth opens without asking: the
    /// least recently used gives up its connection, the count stays at 4, and
    /// that chat comes back whole and working when focused.
    @MainActor
    func testRemoteHostFullOfIdleChatsReleasesTheOldestToOpenAnother() throws {
        try requireLiveProvider()
        let app = try launchLoopback()
        try openChat(app)

        var ids: [String] = []
        var tokens: [String] = []
        for index in 0..<4 {
            if let last = ids.last { openNewChat(app, leaving: last) }
            let token = Self.token("IDLE\(index)")
            tokens.append(token)
            ids.append(sendInCurrentChat(app, "Reply with exactly: \(token)", knownIds: ids))
            failWithEvidence(awaitBubble(app, "Assistant", token), app, "Chat \(index) never replied. state.db: \(rows(session: ids[index]).last?.content ?? "<none>")")
        }
        assertACPProcessesBecome(4, "with four idle chats", overSSH: true)

        // A fifth: no question, and still four connections.
        newChatButton(app).click()
        XCTAssertFalse(staticText(app.sheets.firstMatch, containing: "Every live chat on").waitForExistence(timeout: 5),
                       "Idle chats should be released without asking.")
        assertACPProcessesStay(atMost: 4, for: 8, "after opening a fifth chat", overSSH: true)
        requireNewChatWorks(app, token: Self.token("FIFTH"), leaving: ids, lastPromptShown: tokens[3])
        assertACPProcessesAreExactly(4, "after the fifth chat replied", overSSH: true)

        // The oldest comes back: its transcript, and a working connection.
        select(app, ids[0])
        XCTAssertTrue(bubbleText(app, "Assistant", tokens[0]).waitForExistence(timeout: 45), "The released chat lost its transcript.")
        let again = Self.token("AGAIN")
        _ = sendInCurrentChat(app, "Reply with exactly: \(again)", knownIds: ids, expecting: ids[0])
        failWithEvidence(awaitBubble(app, "Assistant", again), app, "The released chat doesn't work after coming back.")
        XCTAssertEqual(activeRowId(app), ids[0], "The re-attached chat isn't the one on screen.")
        assertACPProcessesStay(atMost: 4, for: 5, "after the released chat came back", overSSH: true)
    }

    // MARK: - Set-up

    private func requireLiveProvider() throws {
        try requireLive()
        let marker = (isolatedHome as NSString).appendingPathComponent(Self.providerVerifiedMarker)
        guard FileManager.default.fileExists(atPath: marker) else {
            throw XCTSkip("No \(Self.providerVerifiedMarker) in the home: these journeys need a fixture from scripts/ui-fixture/make-ui-fixture.sh, whose real chats prove the provider works.")
        }
    }

    private func askForEveryApproval(inHome home: String) throws {
        let path = (home as NSString).appendingPathComponent("config.yaml")
        let config = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(config.contains("approvals:"), "The fixture's config.yaml already has an approvals block; merge instead of appending.")
        try (config + "\napprovals:\n  mode: manual\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func launchLocal() -> XCUIApplication {
        let app = makeApp(extraLaunchArguments: SectionSweepUITests.expandedSidebarLaunchArguments)
        launchAndSurface(app)
        quitAtTheEnd(app)
        return app
    }

    /// A window on the guest's loopback "remote" (scripts/ui-gate-vm.sh seeds
    /// its one servers.json entry, ⌘2). Skips anywhere that isn't set up.
    private func launchLoopback() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let id = environment["SCARF_UITEST_LOOPBACK_ID"],
              let home = environment["SCARF_UITEST_LOOPBACK_HOME"] else {
            throw XCTSkip("No loopback SSH host: this journey needs a remote Hermes, which scripts/ui-gate-vm.sh sets up in the VM for the Live plan.")
        }
        hermesHome = home
        let app = makeApp(extraLaunchArguments: SectionSweepUITests.expandedSidebarLaunchArguments
            + ["-ScarfWindowFrame.Scarf.Window.\(id)", "\"{{40, 140}, {1800, 1300}}\""])
        app.launch()
        app.activate()
        waitForForeground(app, timeout: 15)
        var surfaced = false
        for _ in 1...3 where !surfaced {
            app.typeKey("2", modifierFlags: .command)
            surfaced = app.windows.firstMatch.waitForExistence(timeout: 8)
            if !surfaced { app.activate() }
        }
        XCTAssertTrue(surfaced, "⌘2 didn't open the loopback server's window; is its servers.json entry there?")
        _ = requireTestWindowSize(app)
        quitAtTheEnd(app)
        return app
    }

    /// Quit through ⌘Q, answering the quit confirm that working chats raise,
    /// from a teardown block so a failed test gets it too.
    private func quitAtTheEnd(_ app: XCUIApplication) {
        addTeardownBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, app.state != .notRunning else { return }
                app.activate()
                app.typeKey("q", modifierFlags: .command)
                func exited(within timeout: TimeInterval) -> Bool {
                    let gone = XCTNSPredicateExpectation(
                        predicate: NSPredicate { object, _ in (object as? XCUIApplication)?.state == .notRunning },
                        object: app)
                    return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
                }
                // Nothing working: it exits by itself, and querying an app
                // that is going records "Lost connection to the application".
                // That can still race the query, so a failure in here is
                // expected and not the test's verdict.
                if !exited(within: 4) {
                    let options = XCTExpectedFailure.Options()
                    options.isStrict = false
                    XCTExpectFailure("The app may exit while the quit confirm is looked for.", options: options) {
                        let quit = app.dialogs.buttons["Quit Anyway"].firstMatch
                        if quit.waitForExistence(timeout: 3) { quit.click() }
                    }
                    _ = exited(within: 15)
                }
                self.attachProcessList()
            }
        }
    }

    private func openChat(_ app: XCUIApplication) throws {
        let row = element(app, "sidebar.section.Chat")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "No Chat row in the sidebar.")
        let root = element(app, "Chat.root")
        XCTAssertTrue(clickUntil(row, appears: root, named: "Chat.root", in: app), "Chat never opened.")
        XCTAssertTrue(element(app, "chat.composer.input").waitForExistence(timeout: 30), "Chat has no composer.")
    }

    // MARK: - Chats

    private static func token(_ stem: String) -> String { "\(stem)\(Int.random(in: 1000...9999))" }

    private static func sleepPrompt(_ seconds: Int, _ token: String) -> String {
        // The token leads: the accessibility layer truncates a long text.
        "\(token) This is an automated UI test of the Scarf app on a disposable test machine; the word above is only a marker for the test to find. Use the terminal tool to run, in the foreground with a timeout longer than the sleep: sleep \(seconds) . Then reply with exactly: \(token)"
    }

    /// Send `text` from the composer of the chat on screen and return that
    /// chat's session id. `expecting` is the id when it's already known.
    @discardableResult
    private func sendInCurrentChat(_ app: XCUIApplication, _ text: String, knownIds: [String], expecting: String? = nil) -> String {
        let input = element(app, "chat.composer.input")
        XCTAssertTrue(input.waitForExistence(timeout: 30), "No composer.")
        setText(text, in: input, of: app)
        let send = element(app, "chat.composer.send")
        var sent = false
        for attempt in 1...3 where !sent {
            ensureFrontmost(app)
            if send.exists && send.isEnabled { send.click() }
            sent = waitUntil(timeout: 10, "the composer to clear") { ((input.value as? String) ?? "") != text }
            if !sent { print("[ParallelChats] send attempt \(attempt)/3 left the prompt in the composer.") }
        }
        failWithEvidence(sent, app, "Sending never cleared the composer.")
        let bound = waitUntil(timeout: 60, "the chat's row to report itself active") {
            guard let active = self.activeRowId(app) else { return false }
            return expecting.map { $0 == active } ?? !knownIds.contains(active)
        }
        failWithEvidence(bound, app, "No row became the active chat after sending (active: \(activeRowId(app) ?? "none")).")
        return activeRowId(app) ?? ""
    }

    /// Send a turn the tests need to be long, and return once the model is
    /// really in its `sleep`. The model decides that, not Scarf: now and then
    /// it answers at once without running the tool (a row with 2 messages and
    /// no tool call), and then "still replying" would be false for no fault of
    /// the app's. Such a chat is asked again under a new token, so its early
    /// answer can't pass for the reply a test waits on. No such luck three
    /// times, or no answer at all, is a failure.
    private func sendLongTurn(_ app: XCUIApplication, _ seconds: Int, _ stem: String, knownIds: [String],
                              prompt: ((String) -> String)? = nil,
                              file: StaticString = #filePath, line: UInt = #line) -> (id: String, token: String) {
        var id: String?
        var token = ""
        // ToolCallCard's header: "Tool call terminal, sleep 60".
        let chip = app.windows.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                                  "Tool call", "sleep \(seconds)")).firstMatch
        for attempt in 1...3 {
            token = Self.token(stem)
            let text = prompt?(token) ?? Self.sleepPrompt(seconds, token)
            id = sendInCurrentChat(app, text, knownIds: knownIds, expecting: id)
            let answered = bubbleText(app, "Assistant", token)
            let settled = waitUntil(timeout: 90, "the model to start its sleep") {
                // A model may name the token before running the tool: an answer
                // counts only once the turn is over.
                chip.exists || (answered.exists && !self.rowIsReplying(app, id ?? ""))
            }
            if chip.exists { return (id ?? "", token) }
            failWithEvidence(settled, app, "The model neither started its sleep nor answered.", file: file, line: line)
            print("[ParallelChats] attempt \(attempt): the model answered without running the tool; asking again.")
        }
        failWithEvidence(false, app, "The model never ran its sleep in three tries.", file: file, line: line)
        return (id ?? "", token)
    }

    /// The approval can take the window from the budget sheet between finding
    /// Wait and clicking it. That race isn't the verdict: what must follow is.
    private func clickWaitIfItIsStillThere(_ app: XCUIApplication, within timeout: TimeInterval) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("The budget sheet may give way to the approval.", options: options) {
            let wait = dialogButton(app, "Wait")
            if wait.exists || (timeout > 0 && wait.waitForExistence(timeout: timeout)) { wait.click() }
        }
    }

    private func newChatButton(_ app: XCUIApplication) -> XCUIElement {
        app.windows.buttons["New"].firstMatch
    }

    /// Click New and wait for the chat on screen to be another one.
    private func openNewChat(_ app: XCUIApplication, leaving previous: String) {
        ensureFrontmost(app)
        let moved = waitUntilAfterClicking(newChatButton(app), app, "a new chat to replace \(previous)") {
            self.activeRowId(app) != previous
        }
        failWithEvidence(moved, app, "New didn't open another chat.")
    }

    /// The chat just opened really is a new one, and it works: the last chat's
    /// prompt is gone from the screen, and a prompt sent now is answered there
    /// under a session id no earlier chat had.
    private func requireNewChatWorks(_ app: XCUIApplication, token: String, leaving ids: [String], lastPromptShown: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let moved = waitUntil(timeout: 60, "the last chat to leave the screen") {
            !self.bubbleText(app, "You", lastPromptShown).exists && !ids.contains(self.activeRowId(app) ?? "")
        }
        failWithEvidence(moved, app, "The new chat never took over the window (on screen: \(activeRowId(app) ?? "nothing")).", file: file, line: line)
        let id = sendInCurrentChat(app, "Reply with exactly: \(token)", knownIds: ids)
        failWithEvidence(awaitBubble(app, "Assistant", token), app, "The new chat never answered.", file: file, line: line)
        XCTAssertFalse(ids.contains(id), "The prompt went to an earlier chat.", file: file, line: line)
    }

    private func waitUntilAfterClicking(_ button: XCUIElement, _ app: XCUIApplication, _ what: String, _ condition: @escaping () -> Bool) -> Bool {
        for attempt in 1...3 {
            ensureFrontmost(app)
            if button.exists { button.click() }
            if waitUntil(timeout: attempt == 3 ? 30 : 12, what, condition) { return true }
        }
        return false
    }

    private func select(_ app: XCUIApplication, _ id: String) {
        let row = element(app, Self.rowIdPrefix + id)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "No row for \(id).")
        let moved = waitUntilAfterClicking(row, app, "\(id) to be the chat on screen") { self.activeRowId(app) == id }
        failWithEvidence(moved, app, "Clicking \(id)'s row didn't show that chat (active: \(activeRowId(app) ?? "none")).")
    }

    // MARK: - Rows

    private func activeRowId(_ app: XCUIApplication) -> String? {
        let active = app.windows.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == 'active'", Self.rowIdPrefix))
            .firstMatch
        guard active.exists else { return nil }
        return String(active.identifier.dropFirst(Self.rowIdPrefix.count))
    }

    private func rowLabel(_ app: XCUIApplication, _ id: String) -> String {
        let row = element(app, Self.rowIdPrefix + id)
        return row.exists ? row.label : "<no row>"
    }

    /// The row's composed label leads with its status glyph's ("Replying, …").
    private func rowIsReplying(_ app: XCUIApplication, _ id: String) -> Bool {
        rowLabel(app, id).hasPrefix("Replying,")
    }

    private func requireRow(_ app: XCUIApplication, _ id: String, showsReplying: Bool, _ context: String) {
        let ok = waitUntil(timeout: 30, "\(id) to read Replying") { self.rowIsReplying(app, id) == showsReplying }
        failWithEvidence(ok, app, "\(id)'s row reads \(rowLabel(app, id)) \(context).")
    }

    // MARK: - Transcript

    private func bubbleText(_ app: XCUIApplication, _ role: String, _ token: String) -> XCUIElement {
        app.windows.descendants(matching: .group)
            .matching(NSPredicate(format: "label == %@", role))
            .descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS[c] %@", token))
            .firstMatch
    }

    private func awaitBubble(_ app: XCUIApplication, _ role: String, _ token: String,
                             timeout: TimeInterval = ParallelChatsLiveUITests.replyTimeout) -> Bool {
        let target = bubbleText(app, role, token)
        for _ in 0..<max(1, Int((timeout / 10).rounded())) {
            if target.waitForExistence(timeout: 10) { return true }
            ensureFrontmost(app)
        }
        return false
    }

    /// The app's own words for a stopped turn, in the transcript or a hint.
    private func transcriptMentionsCancel(_ app: XCUIApplication) -> Bool {
        app.windows.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS[c] %@", "Turn cancelled"))
            .firstMatch.exists
    }

    private func staticText(_ container: XCUIElement, containing text: String) -> XCUIElement {
        container.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    private func dialogButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.sheets.firstMatch.buttons[title].firstMatch
    }

    // MARK: - hermes acp processes

    /// The `hermes acp` connections, or nil outside the VM. The loopback host
    /// is this machine, so a remote chat's far side is in the list too.
    private func acpProcessCount(overSSH: Bool) -> Int? {
        guard let path = ProcessInfo.processInfo.environment["SCARF_UITEST_ACP_PROCS"] else { return nil }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        // Hermes's own Python process, not a wrapping shell or an ssh client.
        // SSHTransport pins a remote root home with `-p default`; a local chat
        // runs bare `hermes acp`, so this also tells the two apart.
        let needle = overSSH ? "/venv/bin/hermes -p default acp" : "/venv/bin/hermes acp"
        return lines.filter { $0.contains("/venv/bin/python") && $0.hasSuffix(needle) }.count
    }

    private func acpProcessList() -> String {
        guard let path = ProcessInfo.processInfo.environment["SCARF_UITEST_ACP_PROCS"] else { return "<no process list>" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable: \(path)>"
    }

    private func attachProcessList() {
        let attachment = XCTAttachment(string: acpProcessList())
        attachment.name = "acp-processes"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    private func assertACPProcessesBecome(_ expected: Int, _ context: String, overSSH: Bool = false,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard acpProcessCount(overSSH: overSSH) != nil || ProcessInfo.processInfo.environment["SCARF_UITEST_ACP_PROCS"] != nil else { return }
        let ok = waitUntil(timeout: 45, "\(expected) hermes acp processes \(context)") {
            self.acpProcessCount(overSSH: overSSH) == expected
        }
        XCTAssertTrue(ok, "Expected \(expected) hermes acp connections \(context); saw \(acpProcessCount(overSSH: overSSH).map(String.init) ?? "?"):\n\(acpProcessList())", file: file, line: line)
    }

    /// Exactly `expected`, on a list made after this call (it is rewritten
    /// once a second) and for a few seconds more, so a chat that stopped or
    /// started just now can't slip through on an old list.
    private func assertACPProcessesAreExactly(_ expected: Int, _ context: String, overSSH: Bool = false,
                                              file: StaticString = #filePath, line: UInt = #line) {
        guard ProcessInfo.processInfo.environment["SCARF_UITEST_ACP_PROCS"] != nil else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            let count = acpProcessCount(overSSH: overSSH)
            if count != expected {
                XCTFail("Expected exactly \(expected) hermes acp connections \(context); saw \(count.map(String.init) ?? "?"):\n\(acpProcessList())", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    private func assertACPProcessesStay(atMost limit: Int, for seconds: TimeInterval, _ context: String, overSSH: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard ProcessInfo.processInfo.environment["SCARF_UITEST_ACP_PROCS"] != nil else { return }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let count = acpProcessCount(overSSH: overSSH), count > limit {
                XCTFail("\(count) hermes acp connections \(context), over the budget of \(limit):\n\(acpProcessList())", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    // MARK: - state.db

    private struct StoredRow: CustomStringConvertible {
        let role: String
        let content: String
        var description: String { "\(role):\(content.prefix(60))" }
    }

    /// Read-only (charter C3). Empty when the database or session isn't there.
    private func query<T>(_ sql: String, _ session: String, _ read: (OpaquePointer) -> T) -> [T] {
        let path = (hermesHome as NSString).appendingPathComponent("state.db")
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            XCTFail("Couldn't open \(path) read-only.")
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("Couldn't read \(path): \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(read(stmt!)) }
        return out
    }

    private func rows(session: String) -> [StoredRow] {
        query("SELECT role, COALESCE(content, '') FROM messages WHERE session_id = ?1 AND role IN ('user', 'assistant') ORDER BY id", session) {
            StoredRow(role: String(cString: sqlite3_column_text($0, 0)), content: String(cString: sqlite3_column_text($0, 1)))
        }
    }

    private func sessionExists(_ session: String) -> Bool {
        !query("SELECT id FROM sessions WHERE id = ?1", session) { _ in true }.isEmpty
    }

    // MARK: - Harness

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.windows.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func ensureFrontmost(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        if app.state != .runningForeground {
            app.activate()
            waitForForeground(app, timeout: 10)
        }
    }

    private func waitUntil(timeout: TimeInterval, _ what: String, _ condition: @escaping () -> Bool) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = "Waiting for \(what)"
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Assert, keeping what a failure needs: the window, the banner, the process list.
    private func failWithEvidence(_ condition: Bool, _ app: XCUIApplication, _ message: @autoclosure () -> String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        let text = message()
        attachScreenshot(app, named: "parallel-chats-failure", keepAlways: true)
        let banner = element(app, "error.banner")
        print("[ParallelChats] processes at failure:\n\(acpProcessList())")
        let hints = app.windows.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS[c] %@ OR value CONTAINS[c] %@", "delet", "couldn"))
            .allElementsBoundByIndex.compactMap { $0.value as? String }
        print("[ParallelChats] sheets \(app.sheets.count); hints \(hints)")
        print("[ParallelChats] AX tree at failure:\n\(app.windows.firstMatch.debugDescription.prefix(12000))")
        XCTFail("\(text) Banner: \(banner.exists ? banner.label : "<none>")", file: file, line: line)
    }
}
