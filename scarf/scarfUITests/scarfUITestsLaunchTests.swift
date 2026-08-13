//
//  scarfUITestsLaunchTests.swift
//  scarfUITests
//
//  Created by Alan Wizemann on 3/31/26.
//

import XCTest

/// Launch-screenshot test. Inherits `ScarfUITestCase` for the throwaway
/// Hermes home — see UITestIsolation.swift for why every launch in this
/// target must go through `makeApp()`.
final class scarfUITestsLaunchTests: ScarfUITestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    @MainActor
    func testLaunch() throws {
        let app = makeApp()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
