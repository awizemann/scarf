//
//  CostRenderingUITests.swift
//  scarfUITests
//
//  The on-screen half of the unknown-cost work (P6/P7/P8, t-9c4d7c60).
//
//  ## What it proves
//
//  `SessionCostDisplay` (ScarfCore) is unit-tested to death, and
//  `InsightsAggregatesTests` pins `unknownCostSessionCount`. Neither
//  proves that the three surfaces READING that rule render what it says.
//  Hermes stores an unknown cost as the placeholder `0.0`, so the bug
//  this guards against is a surface quietly formatting that zero as
//  "$0.00" — a number the user reads as fact and Hermes never stated.
//  That failure is invisible to every existing test and obvious on
//  screen, which is exactly the shape the UI gate exists for.
//
//  Three fixture sessions carry the three states
//  (`scripts/ui-fixture/make-ui-fixture.sh`, "seed: cost states"):
//
//  | id                      | cost_status | amount | must render      |
//  |-------------------------|-------------|--------|------------------|
//  | uicost-unknown-0001     | 'unknown'   | 0.0    | "—"              |
//  | uicost-nullstatus-0002  | NULL        | none   | "—"              |
//  | uicost-amount-0003      | 'estimated' | 1.23   | "$1.23"          |
//
//  The first two are the two shapes of "Hermes never priced this"; the
//  third is the control that proves the dash is a rendering of the RULE
//  and not just a dash the table always shows.
//
//  ## Full plan, not Live
//
//  Nothing here needs a running agent or a provider key: the rows are
//  seeded data and the assertions are pure rendering. It therefore runs
//  in Full (the whole scarfUITests target) with no `requireLive()`, and
//  needs no entry in Live.xctestplan.
//
//  ## It SKIPS without the fixture
//
//  `ScarfUITestCase` falls back to an empty isolated home when
//  `SCARF_UITEST_FIXTURE` is unset, and an empty home has no sessions at
//  all — asserting against it would prove nothing. So a missing seeded
//  row is an `XCTSkip` naming the fixture command, never a failure. The
//  gate must not fail on a Mac that simply has not built a fixture.
//
//      FIXTURE="$(scripts/ui-fixture/make-ui-fixture.sh "$(mktemp -d)/fixture-home")"
//      TEST_RUNNER_SCARF_UITEST_FIXTURE="$FIXTURE" \
//        xcodebuild test -project scarf/scarf.xcodeproj -scheme scarf \
//        -destination 'platform=macOS' -testPlan Full \
//        -only-testing:scarfUITests/CostRenderingUITests
//

import XCTest

final class CostRenderingUITests: ScarfUITestCase {

    // MARK: - The seeded rows

    /// Duplicated from `scripts/ui-fixture/make-ui-fixture.sh`'s
    /// "seeded ids" block — this bundle links neither the script nor
    /// ScarfCore, so there is nowhere shared to put them. Change them in
    /// both places together.
    private static let unknownStatusSessionID = "uicost-unknown-0001"
    private static let nullStatusSessionID = "uicost-nullstatus-0002"
    private static let amountSessionID = "uicost-amount-0003"

    /// `COST_AMOUNT_USD` in the fixture script, as the Sessions table
    /// formats it (`.currency(code: "USD").precision(.fractionLength(2))`).
    private static let amountInTable = "$1.23"

    /// `SessionsView.costAccessibilityLabel` / `SessionDetailView`'s
    /// explicit label for the em dash. VoiceOver must not say "cost —",
    /// and this string is the contract that stops it.
    private static let unknownCostLabel = "cost unknown"

    // MARK: - Sessions table

    /// The Sessions table renders the dash for both unknown shapes and
    /// the formatted amount for the priced one — and the dash cell's
    /// accessibility label says what the dash MEANS.
    ///
    /// All three read off the row button's composed accessibility label
    /// (`SessionsView.accessibilityRowLabel`, which ends "… cost <x>,
    /// updated <y>"). The cost cell itself is not separately
    /// addressable: AppKit flattens a `.plain` Button's children into
    /// the button, so the row label IS the surface here — and it is the
    /// thing VoiceOver actually says, which makes it the better
    /// assertion of the two anyway.
    @MainActor
    func testSessionsTableRendersTheThreeCostStates() throws {
        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Sessions")
        let unknownRow = try requireSeededRow(app, Self.unknownStatusSessionID)

        // 1. cost_status = 'unknown' with the placeholder zero AND real
        //    tokens. The tokens matter: they are what makes "$0.00" look
        //    plausible, since a session that burned 4,210 input tokens
        //    obviously cost something.
        assertCostReads(unknownRow, is: Self.unknownCostLabel, id: Self.unknownStatusSessionID)

        // 2. cost_status NULL on a host that HAS the column — a session
        //    that never completed a priced turn. Same dash. This is the
        //    case the first fix got wrong (it read NULL as "old host"
        //    and rendered "$0.00"), so it is the one with teeth.
        let nullRow = try requireSeededRow(app, Self.nullStatusSessionID)
        assertCostReads(nullRow, is: Self.unknownCostLabel, id: Self.nullStatusSessionID)

        // 3. The control: a positive estimate still renders as money. A
        //    "fix" that dashed everything would pass 1 and 2.
        let amountRow = try requireSeededRow(app, Self.amountSessionID)
        assertCostReads(amountRow, is: "cost \(Self.amountInTable)", id: Self.amountSessionID)
        XCTAssertFalse(
            axText(of: amountRow).contains(Self.unknownCostLabel),
            "The priced session reads as unknown: \(axText(of: amountRow))"
        )

        attachScreenshot(app, named: "sessions-cost-states", keepAlways: false)
    }

    // MARK: - Session detail

    /// Opening an unknown-cost session shows the dash in the detail
    /// header too, with the same "cost unknown" label.
    ///
    /// Worth its own test because the two surfaces used to DISAGREE
    /// about the same row: `SessionsView` rendered "$0.00" while
    /// `SessionDetailView` rendered nothing at all. One shared rule is
    /// the fix, and two surfaces asserting the same string is how that
    /// stays true.
    @MainActor
    func testSessionDetailRendersTheDashForAnUnknownCost() throws {
        let app = launchExpanded()
        defer { gracefulQuit(app) }

        try openSection(app, "Sessions")
        let row = try requireSeededRow(app, Self.unknownStatusSessionID)

        // The detail pane prints the session id verbatim
        // (`SessionDetailView.sessionHeader`), which is how we know we
        // are looking at the row we clicked and not whichever session
        // the pane happened to have open.
        let idText = app.windows.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value == %@", Self.unknownStatusSessionID))
            .firstMatch
        guard clickUntil(row, appears: idText, named: "the session detail header", in: app) else {
            attachScreenshot(app, named: "session-detail-never-opened", keepAlways: true)
            XCTFail("Clicking sessions.row.\(Self.unknownStatusSessionID) never opened its detail (no static text carrying the session id).")
            return
        }

        // `SessionDetailView` gives the em-dash Label an explicit
        // `.accessibilityLabel("cost unknown")`, so this is a label
        // match, not a value match — the one place in this file where
        // that is true, and it is true because the app says so
        // explicitly rather than because SwiftUI composed it.
        let unknownCost = app.windows.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", Self.unknownCostLabel))
            .firstMatch
        if !unknownCost.waitForExistence(timeout: 10) {
            attachScreenshot(app, named: "session-detail-no-cost-label", keepAlways: true)
            print("[CostRendering] detail AX tree:\n\(app.windows.firstMatch.debugDescription)")
        }
        XCTAssertTrue(
            unknownCost.exists,
            "The detail header for \(Self.unknownStatusSessionID) carries nothing labelled \"\(Self.unknownCostLabel)\". Either it is rendering a currency amount for a cost Hermes never knew, or the em dash lost its accessibility label and VoiceOver now says \"cost —\"."
        )
        attachScreenshot(app, named: "session-detail-cost-unknown", keepAlways: false)
    }

    // MARK: - Insights

    /// The Insights Total Cost card refuses to assert a complete total
    /// while any session is unpriced.
    ///
    /// What the implementation actually does
    /// (`InsightsView.totalCostCard`): with
    /// `unknownCostSessionCount > 0` it attaches a "Partial — Hermes
    /// recorded no cost for N sessions" help/value, and when the sum is
    /// ALSO zero it replaces the figure with "—" and reads "cost
    /// unknown". Which of the two is on screen depends on whether the
    /// fixture's three real `-z` sessions happened to be priced — that
    /// is genuinely non-deterministic (it turns on whether the
    /// configured model has a pricing entry), so this asserts the
    /// invariant that holds either way: the card must NOT read as a
    /// plain, complete total. The seeded unknown rows guarantee
    /// `unknownCostSessionCount > 0`, so one of the two markers must be
    /// there.
    @MainActor
    func testInsightsTotalCostMarksItselfPartialWhileSessionsAreUnpriced() throws {
        let app = launchExpanded()
        defer { gracefulQuit(app) }

        // Insights reads the same sessions; if the fixture is missing,
        // there is nothing unpriced and nothing to assert.
        try openSection(app, "Sessions")
        _ = try requireSeededRow(app, Self.unknownStatusSessionID)

        try openSection(app, "Insights")
        let card = app.windows.descendants(matching: .any)
            .matching(identifier: "insights.totalCost")
            .firstMatch
        guard card.waitForExistence(timeout: 20) else {
            attachScreenshot(app, named: "insights-no-total-cost-card", keepAlways: true)
            XCTFail("No insights.totalCost element — the identifier moved off InsightsView's Total Cost card, or the `.accessibilityElement(children: .combine)` that makes it one element was removed.")
            return
        }

        let text = axText(of: card)
        XCTAssertTrue(
            text.contains("Partial") || text.contains(Self.unknownCostLabel) || text.contains("—"),
            "The Total Cost card reads \"\(text)\" with unpriced sessions on the board. It must carry the partial marker (or the em dash when the known sum is zero) rather than presenting an incomplete sum as the total."
        )
        attachScreenshot(app, named: "insights-total-cost-partial", keepAlways: false)
    }

    // MARK: - Assertions

    /// Assert the row's cost fragment, with the whole label in the
    /// failure message.
    ///
    /// Substring, not equality: the fragment sits inside a composed
    /// sentence ("<title>, model <m>, 6 messages, 5.4K tokens, cost
    /// unknown, updated 1 min ago"). A failure prints the full text
    /// because the two interesting ways this breaks — a wrong cost, and
    /// a label the accessibility layer truncated before reaching the
    /// cost — look identical without it.
    private func assertCostReads(
        _ row: XCUIElement,
        is fragment: String,
        id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = axText(of: row)
        XCTAssertTrue(
            text.contains(fragment),
            "sessions.row.\(id) does not read \"\(fragment)\". Its accessibility text is: \"\(text)\". If the cost fragment is missing entirely rather than wrong, the label was truncated and this assertion needs a dedicated element, not a substring.",
            file: file,
            line: line
        )
    }

    /// Label and value joined, because SwiftUI splits content across the
    /// two unpredictably: a `Text` publishes as the VALUE, while a
    /// composed control label is the LABEL. Reading both is what makes
    /// these assertions robust to that split rather than to guesses
    /// about it.
    private func axText(of element: XCUIElement) -> String {
        guard element.exists else { return "<element does not exist>" }
        let value = (element.value as? String) ?? ""
        return value.isEmpty ? element.label : "\(element.label) \(value)"
    }

    // MARK: - Fixture gate

    /// The seeded row, or a skip explaining how to get one.
    ///
    /// Deliberately a SKIP: without `SCARF_UITEST_FIXTURE` the isolated
    /// home is empty, so this suite would be asserting against a table
    /// with no rows. A gate that fails on a machine without a built
    /// fixture is a gate people switch off.
    private func requireSeededRow(_ app: XCUIApplication, _ id: String) throws -> XCUIElement {
        let row = app.windows.descendants(matching: .any)
            .matching(identifier: "sessions.row.\(id)")
            .firstMatch
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "No sessions.row.\(id) in the Sessions table. This suite needs the seeded fixture home: "
                + "FIXTURE=\"$(scripts/ui-fixture/make-ui-fixture.sh \"$(mktemp -d)/fixture-home\")\" "
                + "TEST_RUNNER_SCARF_UITEST_FIXTURE=\"$FIXTURE\" xcodebuild test … -testPlan Full"
            )
        }
        return row
    }

    // MARK: - Harness (same shapes as ChatJourneyUITests)

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

    /// Click a sidebar section and wait for its root, retrying the click
    /// — a click landing while the app is not frontmost is dropped
    /// silently and re-clicking a selected row is a no-op. Neither
    /// Sessions nor Insights is capability-gated, so a missing row is a
    /// failure, never a skip.
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
            print("[CostRendering] \(section).root absent after click attempt \(attempt)/3; retrying.")
        }
        XCTFail("\(section).root never appeared after clicking its sidebar row three times.")
    }
}
