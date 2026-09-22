//
//  ChatJourneyUITests.swift
//  scarfUITests
//
//  The Live-plan half of the UI release gate: Chat over ACP against a
//  REAL `hermes` process and a REAL provider key (plan P2d,
//  t-d714835d).
//
//  ## What it proves
//
//  Everything else in this target asserts against files, sections and
//  identifiers — surfaces that render without a model ever being
//  called. This journey is the only one that proves the product's
//  headline path end to end:
//
//      composer → `ChatViewModel.sendText` → `autoStartACPAndSend`
//      → `hermes acp` subprocess → provider → streamed reply bubble
//      → a new row in `state.db`, visible in the Sessions section.
//
//  A regression anywhere on that chain (a broken ACP argv, the
//  pre-engagement gate swallowing `promptComplete`, a wedged start with
//  no watchdog — all shipped bugs, see the chat-session-layer memory
//  note) renders a perfectly healthy-looking Chat section and fails
//  here and nowhere else.
//
//  ## Why it is Live-only, and how it skips
//
//  It spends real tokens on a real provider. `requireLive()` keeps it
//  out of Smoke and Full (only `Live.xctestplan` sets
//  `SCARF_UITEST_LIVE=1`) and out of a machine with no `hermes`
//  binary. On top of that this file PROBES the copied credentials with
//  a cheap one-shot `hermes -z` before touching the UI: a home whose
//  `auth.json` has no usable provider would otherwise fail 90 s later
//  as "no reply bubble", which reads as a product bug and is not one.
//  A failed probe is an XCTSkip quoting the CLI's own stderr.
//
//  ## Isolation
//
//  `ScarfUITestCase` pins the app AND the `hermes acp` process it
//  spawns at a per-test throwaway home (`SCARF_HERMES_HOME` +
//  `HERMES_HOME`). Because this is the one journey that writes
//  SESSIONS, tearDown re-checks the modification time of the
//  developer's real `~/.hermes/state.db`: if a session this test
//  created landed there, the harness leaked and that must fail loudly
//  rather than quietly growing someone's real history.
//

import XCTest

final class ChatJourneyUITests: ScarfUITestCase {

    // MARK: - Journey constants

    /// Deliberately SHORT and deterministic.
    ///
    /// Every character is a separately synthesized event and macOS
    /// drops and reorders them under load (see the input-reliability
    /// memory note), so a long prompt is a long odds-against-it bet.
    /// `setText` reads the field back and retries, but the cheapest fix
    /// is fewer keystrokes.
    private static let prompt = "Reply with exactly: PONG"

    /// The token the REPLY must contain.
    ///
    /// It also appears in the prompt, so the user's own bubble matches
    /// any naive search — `replyToken` is always paired with
    /// `isReplyLabel(_:)`, which excludes the echo.
    private static let replyToken = "PONG"

    /// `RichMessageBubble`'s accessibility label for an assistant
    /// bubble — the role, which is what separates the model's answer
    /// from the user's echo of a prompt that contains the same token.
    private static let assistantBubbleLabel = "Assistant"

    /// Upper bound on the whole turn: ACP spawn, `session/new`,
    /// provider round trip, first painted assistant bubble.
    ///
    /// Polled in small steps rather than as one long `waitForExistence`
    /// — a single 60 s idle wait has been observed to leave the app
    /// with no window at all and take the rest of the invocation down
    /// with it.
    private static let replyTimeout: TimeInterval = 90

    /// Seeded ACP chats for the Kanban-badge journey. Duplicated from
    /// `scripts/ui-fixture/make-ui-fixture.sh`'s "seeded ids" block —
    /// this bundle links neither the script nor ScarfCore, so there is
    /// nowhere shared to put them. Change them in both places together.
    /// The first owns one `running` + one `review` task; the second owns
    /// none.
    private static let badgeChatWithTasks = "uibadge-acp-0001"
    private static let badgeChatWithoutTasks = "uibadge-acp-0003"

    // MARK: - Real-home tripwire

    /// Modification time of the developer's real `~/.hermes/state.db`
    /// at setUp, or nil when they have no Hermes install.
    private var realStateDBModified: Date?

    private static var realStateDBPath: String {
        ((realHome as NSString).appendingPathComponent(".hermes") as NSString)
            .appendingPathComponent("state.db")
    }

    private static func modificationDate(ofFileAt path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        realStateDBModified = Self.modificationDate(ofFileAt: Self.realStateDBPath)
    }

    override func tearDownWithError() throws {
        // Runs even when the test failed, which is when it matters most:
        // a leak that also broke the journey must still be diagnosed as
        // a leak.
        let after = Self.modificationDate(ofFileAt: Self.realStateDBPath)
        XCTAssertEqual(
            after, realStateDBModified,
            "\(Self.realStateDBPath) was written while the chat journey ran — the isolated home leaked and this test just added a session to the developer's real Hermes history. Check SCARF_HERMES_HOME/HERMES_HOME on every launch."
        )
        realStateDBModified = nil
        try super.tearDownWithError()
    }

    // MARK: - Journey: send a prompt, get a reply, get a session

    /// Type a deterministic prompt into Chat, send it over ACP, assert
    /// the assistant's reply bubble renders, then assert the Sessions
    /// section has gained exactly the one session the turn created.
    ///
    /// Run it for real with:
    ///
    ///     FIXTURE="$(scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home")"
    ///     TEST_RUNNER_SCARF_UITEST_FIXTURE="$FIXTURE" \
    ///       xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf \
    ///       -destination 'platform=macOS' -testPlan Live \
    ///       -only-testing:scarfUITests/ChatJourneyUITests
    @MainActor
    func testChatSendsAPromptOverACPAndTheSessionAppearsInSessions() throws {
        try requireLive()
        try requireUsableProvider()

        let app = launchExpanded()
        defer { gracefulQuit(app) }

        // Baseline FIRST, from the same surface the assertion reads, so
        // the two numbers can never disagree about what "a session"
        // means. The fixture home already carries seeded sessions, so a
        // hard-coded "1" would be wrong there and right on an empty
        // home; the delta is what is actually being tested.
        try openSection(app, "Sessions")
        // No stats line means no sessions AT ALL, not a broken read: on a
        // freshly minted isolated home nothing has created `state.db` yet,
        // so `SessionsViewModel.loadImpl` returns at its `guard opened`
        // and `storeStats` stays nil (the header falls back to its static
        // tagline). That is precisely the zero this journey starts from
        // when it runs without a seeded fixture, so it counts as 0 rather
        // than failing — the assertion that has teeth is the delta below,
        // which still requires a rendered "1 sessions · …" afterwards.
        let sessionsBefore = waitForSessionCount(app, timeout: 20) ?? 0

        try openSection(app, "Chat")

        // MARK: Compose

        let input = element(app, "chat.composer.input")
        XCTAssertTrue(
            input.waitForExistence(timeout: 25),
            "Chat rendered but has no chat.composer.input — the identifier moved off the composer's TextEditor."
        )
        // `setText` types AND READS THE VALUE BACK, retrying the whole
        // click/select-all/type sequence when characters were dropped.
        // Never assume a `typeText` landed.
        setText(Self.prompt, in: input, of: app)
        XCTAssertEqual(
            input.value as? String, Self.prompt,
            "The composer does not hold the prompt verbatim — sending now would ask the model something else and the PONG assertion would fail for the wrong reason."
        )

        // MARK: Send

        let send = element(app, "chat.composer.send")
        XCTAssertTrue(
            send.waitForExistence(timeout: 15),
            "No chat.composer.send button — the identifier moved off the composer's send Button."
        )
        // The observable outcome of a send is the composer CLEARING
        // (`RichChatInputBar.send()` empties `text` before calling
        // `onSend`). Retry on that rather than on the reply: a dropped
        // click is cheap to redo now, and re-clicking after a landed
        // send is a no-op because `canSend` is false on an empty field.
        var sent = false
        for attempt in 1...3 {
            ensureFrontmost(app)
            if send.exists && send.isEnabled { send.click() }
            let cleared = waitUntil(timeout: 10, describing: "the composer to clear after send") {
                let value = (input.value as? String) ?? ""
                return value != Self.prompt
            }
            if cleared {
                sent = true
                break
            }
            print("[ChatJourney] send click attempt \(attempt)/3 left the prompt in the composer; retrying.")
        }
        XCTAssertTrue(sent, "Clicking chat.composer.send three times never cleared the composer — the send action is not firing.")

        // MARK: Await the reply

        // Chunked `waitForExistence` on a LAZY `firstMatch`, not a
        // polling closure that enumerates the matches.
        //
        // Both halves of that are load-bearing. Enumerating
        // (`allElementsBoundByIndex`) on every tick while the transcript
        // streams resolves every match against a tree that is being
        // rebuilt underneath it, and that raised "Failed to resolve
        // remote element … Interrupted by waiter" — recorded as a test
        // FAILURE at the query line, which then masked the real
        // diagnosis. And the chunking is the other memory-note rule: one
        // long idle wait has been observed to leave the app with no
        // window at all, so the 90 s budget is spent as nine 10 s waits
        // with a frontmost check between them.
        let reply = replyQuery(app).firstMatch
        var gotReply = false
        let chunk: TimeInterval = 10
        for _ in 1...Int((Self.replyTimeout / chunk).rounded()) {
            if reply.waitForExistence(timeout: chunk) { gotReply = true; break }
            ensureFrontmost(app)
        }
        if !gotReply {
            attachScreenshot(app, named: "chat-no-reply", keepAlways: true)
            // What DID render — the single most useful thing to have in
            // the log when the answer is "the reply is there but the
            // label does not look how the test expected".
            print("[ChatJourney] transcript labels on screen at timeout: \(visibleTranscriptLabels(app))")
            print("[ChatJourney] AX tree at timeout:\n\(app.windows.firstMatch.debugDescription)")
            // The banner is the app's own explanation (bad credentials,
            // a refused session, a dead ACP process) and is far more
            // useful in a result bundle than "element not found".
            let banner = element(app, "error.banner")
            let bannerText = banner.exists ? banner.label : "<no error.banner on screen>"
            XCTFail(
                "No assistant bubble containing \"\(Self.replyToken)\" within \(Int(Self.replyTimeout))s of sending \"\(Self.prompt)\". Chat error banner: \(bannerText)"
            )
            return
        }
        attachScreenshot(app, named: "chat-reply-rendered", keepAlways: false)

        // MARK: The turn produced a session

        try openSection(app, "Sessions")
        // Polled, not read once: `SessionsViewModel.load()` is async and
        // the section's `.task` has to finish a state.db read (through
        // the WAL the ACP process just wrote) before the stats line
        // catches up.
        let counted = waitUntil(timeout: 45, describing: "Sessions to list one more session than before") {
            self.listedSessionCount(app) == sessionsBefore + 1
        }
        if !counted {
            attachScreenshot(app, named: "sessions-after-chat", keepAlways: true)
        }
        XCTAssertTrue(
            counted,
            "Sessions lists \(listedSessionCount(app).map(String.init(describing:)) ?? "<no stats line>") sessions; expected \(sessionsBefore + 1) after one chat turn. The reply rendered, so the turn ran — this is Scarf's state.db read, not the model."
        )
        attachScreenshot(app, named: "sessions-lists-the-new-session", keepAlways: false)
    }

    // MARK: - Journey: the Kanban chip's count follows the chat

    /// Switching chats must RESET the Kanban badge, and the count must
    /// include tasks parked in `review`.
    ///
    /// Both halves shipped broken (t-f0a94093): the chip kept asserting
    /// the previous chat's number after a switch, and `review` — the
    /// status most urgently waiting on the person reading the badge —
    /// was left out of the count entirely, so a card parked for approval
    /// read as 0. `KanbanChatBadgeStateTests` pins the state machine;
    /// this proves the chip on screen is actually driven by it, which no
    /// unit test can (the binding runs through
    /// `ChatTranscriptPane`'s `.task(id:)`, the ACP session id, and a
    /// 5 s poll of the real `hermes kanban list --session`).
    ///
    /// The fixture seeds three ACP chats: two owning a `running` + a
    /// `review` task each (so the chip must read **2**), and one owning
    /// none (**0**). Sequence: open A → 2, switch to the empty one → 0,
    /// switch back to A → 2. The middle step is the regression; the
    /// third is what separates "the badge reset" from "the badge stopped
    /// working".
    ///
    /// Live-only because the chip is capability-gated on a real host
    /// (`hasKanbanSessionFilter`, Hermes v0.15+) and each tick spawns a
    /// real `hermes kanban list`. `Live.xctestplan` selects this whole
    /// SUITE by class name, so it needs no new entry there.
    @MainActor
    func testKanbanChipCountFollowsTheChatAndCountsReview() throws {
        try requireLive()

        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Chat")

        let withTasks = try requireSeededChat(app, Self.badgeChatWithTasks)
        let withoutTasks = try requireSeededChat(app, Self.badgeChatWithoutTasks)

        // Open the chat that owns two live tasks. `bindChat` waits for
        // the row to report itself ACTIVE — i.e. the pane's session id
        // really is this one — because a resume whose ACP `session/load`
        // is refused falls back to a brand-new session with a different
        // id, and the badge would then be truthfully reporting a chat
        // this test did not mean.
        try bindChat(app, withTasks, id: Self.badgeChatWithTasks)

        let chip = element(app, "chat.kanbanChip")
        guard chip.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "No chat.kanbanChip in the chat header. The chip is gated on `hasKanbanSessionFilter` (Hermes v0.15+), so an older host legitimately has none — that is a skip, not a failure."
            )
        }

        assertChipReads(app, chip, "2", after: "opening \(Self.badgeChatWithTasks) (one running + one review task)")

        // The regression: switching away must clear the number, not keep
        // asserting the previous chat's.
        try bindChat(app, withoutTasks, id: Self.badgeChatWithoutTasks)
        assertChipReads(app, chip, "0", after: "switching to \(Self.badgeChatWithoutTasks), which owns no tasks")

        // And back — proving the reset above was a rebind, not the
        // poller dying.
        try bindChat(app, withTasks, id: Self.badgeChatWithTasks)
        assertChipReads(app, chip, "2", after: "switching back to \(Self.badgeChatWithTasks)")

        attachScreenshot(app, named: "kanban-chip-follows-the-chat", keepAlways: false)
    }

    // MARK: - Kanban chip helpers

    /// A seeded chat row, or a skip naming the fixture command.
    private func requireSeededChat(_ app: XCUIApplication, _ id: String) throws -> XCUIElement {
        let row = element(app, "chat.session.\(id)")
        guard row.waitForExistence(timeout: 25) else {
            throw XCTSkip(
                "No chat.session.\(id) in the chat list. This journey needs the seeded fixture home: "
                + "FIXTURE=\"$(scripts/ui-fixture/make-ui-fixture.sh \"$(mktemp -d)/fixture-home\")\" "
                + "TEST_RUNNER_SCARF_UITEST_FIXTURE=\"$FIXTURE\" xcodebuild test … -testPlan Live"
            )
        }
        return row
    }

    /// Click a chat row and wait until the pane is genuinely BOUND to
    /// that session id (`ChatSessionRow`'s accessibility value flips to
    /// "active" when `session.id == richChat.sessionId`).
    ///
    /// A skip rather than a failure when the bind never happens: that
    /// means Hermes's ACP refused `session/load` for the seeded row and
    /// `ChatViewModel` fell back to `newSession`, which is correct
    /// behaviour for an unloadable session and says nothing about the
    /// badge. It would be dishonest to fail the badge test for it — but
    /// the message has to name the cause, because the symptom (a chip
    /// reading 0 forever) looks exactly like the bug this test guards.
    private func bindChat(_ app: XCUIApplication, _ row: XCUIElement, id: String) throws {
        let bound = clickUntil(
            row,
            appears: app.windows.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ AND value == 'active'", "chat.session.\(id)"))
                .firstMatch,
            named: "chat.session.\(id) to report itself active",
            in: app
        )
        guard bound else {
            attachScreenshot(app, named: "chat-never-bound-\(id)", keepAlways: true)
            throw XCTSkip(
                "Clicking chat.session.\(id) never bound the pane to that session id. `ChatViewModel.resumeSession` asks ACP to `session/load` it and falls back to a NEW session when Hermes refuses, so a seeded row this host's agent cannot restore lands here. The badge assertions need the seeded id to be the bound one, so they are skipped rather than run against a different session."
            )
        }
    }

    /// Poll the chip's accessibility value until it equals `expected`.
    ///
    /// The value is the count as a string, published by
    /// `SessionInfoBar`; empty means "no poll has landed for this chat
    /// yet", which is why "0" and "" must not be conflated — a chip that
    /// simply never updated would otherwise pass the reset assertion.
    /// The budget is generous because the poller ticks every 5 s and
    /// each tick spawns a real `hermes kanban list`, but it is spent by
    /// `waitUntil`'s re-querying predicate rather than as one long idle
    /// wait.
    private func assertChipReads(
        _ app: XCUIApplication,
        _ chip: XCUIElement,
        _ expected: String,
        after context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matched = waitUntil(timeout: 40, describing: "the Kanban chip to read \(expected) after \(context)") {
            (chip.value as? String) == expected
        }
        if !matched {
            attachScreenshot(app, named: "kanban-chip-\(expected)-expected", keepAlways: true)
        }
        XCTAssertTrue(
            matched,
            "The Kanban chip reads \"\((chip.value as? String) ?? "<no value>")\" after \(context); expected \"\(expected)\". An empty value means no poll landed for this chat at all; the previous chat's number means the rebind did not clear it; 1 instead of 2 means `review` is not being counted (KanbanChatBadgeState.liveStatuses).",
            file: file,
            line: line
        )
    }

    // MARK: - Reply detection

    /// Text inside an ASSISTANT bubble carrying the reply token.
    ///
    /// Two things about Scarf's accessibility tree drive the shape of
    /// this query, and both were established by dumping the tree from a
    /// failing run rather than guessed:
    ///
    /// 1. **SwiftUI `Text` publishes its content as the AX `value`, not
    ///    the `label`.** A `label CONTAINS "PONG"` predicate matches
    ///    nothing in the transcript — it only ever hits the chat
    ///    sidebar's row Button, whose label is a composed summary. Every
    ///    text predicate in this file therefore reads `value`.
    /// 2. **`RichMessageBubble` wraps each bubble in a Group whose label
    ///    is the ROLE** ("You" / "Assistant",
    ///    `RichMessageBubble.swift`'s `accessibilityLabel`). Scoping to
    ///    that group is what makes this a real assertion: the prompt
    ///    contains the token by construction, so an unscoped search
    ///    would pass on the user's own echo and prove nothing about the
    ///    model ever having answered.
    private func replyQuery(_ app: XCUIApplication) -> XCUIElementQuery {
        app.windows
            .descendants(matching: .group)
            .matching(NSPredicate(format: "label == %@", Self.assistantBubbleLabel))
            .descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS[c] %@", Self.replyToken))
    }

    /// Every static-text VALUE under the app's windows, for the failure
    /// log.
    ///
    /// Only ever called from a failure branch: this is the expensive
    /// enumeration the reply poll deliberately avoids, and running it
    /// per tick is what made the poll itself raise "Failed to resolve
    /// remote element … Interrupted by waiter".
    private func visibleTranscriptLabels(_ app: XCUIApplication) -> [String] {
        app.windows.descendants(matching: .staticText)
            .allElementsBoundByIndex
            .prefix(60)
            .compactMap { $0.exists ? ($0.value as? String) : nil }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Sessions count

    /// The session count off the Sessions page header
    /// (`"\(stats.totalSessions) sessions · …"`, SessionsView.swift),
    /// or nil when the stats line is not on screen.
    ///
    /// Read from the RENDERED header rather than by opening state.db
    /// from the test: this asserts what the user can see, and charter
    /// C3 keeps the test out of that database as much as it keeps Scarf
    /// out of it. `stats.totalSessions` is `sessions.count` — the length
    /// of the list the view just rendered — so this is genuinely "is it
    /// listed", not a side channel.
    /// Matched on `value` and on " sessions" alone, NOT on the full
    /// "N sessions · M messages · SIZE" string: SwiftUI publishes `Text`
    /// content as the AX value, and the accessibility layer TRUNCATES a
    /// long one with an ellipsis ("Reply with exactly…" for a 24-char
    /// prompt), so anything after the first word is not reliably there.
    /// The leading integer always is, and it is the only part read.
    private func listedSessionCount(_ app: XCUIApplication) -> Int? {
        let stats = app.windows.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value CONTAINS %@", " sessions"))
        for element in stats.allElementsBoundByIndex where element.exists {
            guard let text = element.value as? String,
                  let space = text.firstIndex(of: " ") else { continue }
            if let count = Int(text[text.startIndex..<space]) { return count }
        }
        return nil
    }

    /// `listedSessionCount`, but waits for the async `.task` load to
    /// paint the stats line at all (it renders a static tagline until
    /// `storeStats` arrives).
    private func waitForSessionCount(_ app: XCUIApplication, timeout: TimeInterval) -> Int? {
        _ = waitUntil(timeout: timeout, describing: "the Sessions stats line") {
            self.listedSessionCount(app) != nil
        }
        return listedSessionCount(app)
    }

    // MARK: - Provider probe

    /// Skip unless the credentials copied into this test's isolated
    /// home actually reach a provider.
    ///
    /// One cheap one-shot turn through the CLI, against the SAME home
    /// the app is about to use, so the probe and the journey can never
    /// disagree about which credentials are in play. Bounded at 60 s:
    /// a provider slow enough to miss that is not one this gate can
    /// hold a 90 s UI timeout open for either.
    private func requireUsableProvider() throws {
        let result = runHermes(["-z", "Reply with exactly: PING"], timeout: 60)
        guard result.code == 0 else {
            throw XCTSkip(
                "The credentials copied into the isolated Hermes home give no usable provider — `hermes -z` exited \(result.code). stderr: \(Self.trimmedForSkip(result.stderr))"
            )
        }
    }

    /// Keep a skip message readable: a provider SDK can emit a hundred
    /// lines of traceback, and the first lines are the diagnosis.
    private static func trimmedForSkip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "<empty>" }
        return trimmed.count <= 600 ? trimmed : String(trimmed.prefix(600)) + "…"
    }

    /// Run the real `hermes` CLI against THIS TEST'S isolated home.
    ///
    /// `HERMES_HOME` is passed explicitly and is the whole safety
    /// story: without it the CLI reads `~/.hermes` and the probe would
    /// bill — and worse, WRITE a session into — the developer's real
    /// home, which the tearDown tripwire would then (correctly) report
    /// as a leak.
    @discardableResult
    private func runHermes(_ arguments: [String], timeout: TimeInterval = 60) -> (code: Int32, stdout: String, stderr: String) {
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

        // Charter C10's spirit applied to the test side: every
        // subprocess gets a timeout. A wedged CLI must skip or fail this
        // journey, not hang the gate until Xcode's own limit fires with
        // nothing to read.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        do {
            try process.run()
        } catch {
            watchdog.cancel()
            return (-1, "", "failed to spawn hermes: \(error)")
        }
        // Drain BEFORE waiting for exit: a full pipe blocks the child
        // forever.
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

    // MARK: - Harness (same shapes as ConfigJourneyUITests)

    /// Look controls up under the app's WINDOWS, never app-wide: AppKit
    /// mirrors some buttons into a Touch Bar proxy that an app-wide
    /// `.firstMatch` can resolve to first, and clicking that fails with
    /// "cannot be called with Touch Bar elements".
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.windows.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func launchExpanded() -> XCUIApplication {
        let app = makeApp(extraLaunchArguments: SectionSweepUITests.expandedSidebarLaunchArguments)
        launchAndSurface(app)
        assertAllSidebarSectionsExpanded(app)
        return app
    }

    /// Bring `app` back to the front before synthesizing events into
    /// it. Conditional, deliberately — an unconditional `activate()`
    /// measurably makes things worse.
    private func ensureFrontmost(_ app: XCUIApplication) {
        guard app.state != .notRunning else { return }
        if app.state != .runningForeground {
            app.activate()
            waitForForeground(app, timeout: 10)
        }
    }

    /// Click into a sidebar section and wait for its root, retrying the
    /// click: a click that lands while the app is not frontmost is
    /// dropped silently, and re-clicking an already-selected row is a
    /// no-op. Neither Chat nor Sessions is capability-gated, so a
    /// missing row is a failure, never a skip.
    private func openSection(_ app: XCUIApplication, _ section: String) throws {
        ensureFrontmost(app)
        let row = element(app, "sidebar.section.\(section)")
        if !row.waitForExistence(timeout: 20) { ensureFrontmost(app) }
        guard row.waitForExistence(timeout: 20) else {
            XCTFail("sidebar.section.\(section) is missing and \(section) is not capability-gated.")
            return
        }
        let root = element(app, "\(section).root")
        for attempt in 1...3 {
            ensureFrontmost(app)
            row.click()
            if root.waitForExistence(timeout: 15) { return }
            print("[ChatJourney] \(section).root absent after click attempt \(attempt)/3; retrying.")
        }
        XCTFail("\(section).root never appeared after clicking its sidebar row three times.")
    }

    /// Poll `condition` until it holds or `timeout` elapses.
    ///
    /// `XCTNSPredicateExpectation` POLLS (~1 Hz) and re-queries the
    /// accessibility tree on every tick, which is what makes a long
    /// wait here safe where a single long `waitForExistence` is not.
    private func waitUntil(
        timeout: TimeInterval,
        describing what: String,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        expectation.expectationDescription = "Waiting for \(what)"
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
