//
//  scarfUITests.swift
//  scarfUITests
//
//  Created by Alan Wizemann on 3/31/26.
//

import XCTest

/// Smoke + launch-performance coverage. Inherits `ScarfUITestCase` so
/// both tests run against a per-test throwaway Hermes home rather than
/// the developer's real `~/.hermes` — Scarf writes on launch (registry
/// migration, AGENTS.md refresh), so even "just launch it" is a writer.
final class scarfUITests: ScarfUITestCase {

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test. Always
        // via `makeApp()` — a bare `XCUIApplication()` escapes isolation.
        let app = makeApp()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        // Each iteration gets a fresh, still-isolated app instance; the
        // throwaway home is shared across iterations, which is exactly
        // what an unmodified `~/.hermes` gave the old version — same
        // warm-cache shape, just not the user's data.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeApp().launch()
        }
    }
}
