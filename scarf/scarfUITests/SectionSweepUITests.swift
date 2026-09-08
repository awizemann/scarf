//
//  SectionSweepUITests.swift
//  scarfUITests
//
//  The breadth half of the UI release gate: prove that EVERY sidebar
//  section still renders, in one app launch, with a screenshot each.
//
//  ## What this catches (and what it deliberately doesn't)
//
//  Catches: a section that crashes the app, a section whose detail view
//  never appears (broken routing, a view that traps on empty data), and a
//  section that comes up showing an error banner. Those are the failures
//  that a journey test would only find by accident, and they are exactly
//  the ones a release must not ship.
//
//  Does NOT catch: wrong content. This is a smoke sweep, not a
//  verification of what each view says. Depth belongs in journeys.
//
//  ## Contracts it depends on
//
//  - `sidebar.section.<rawValue>` on every sidebar row (SidebarView.row,
//    plus the projects well header for Projects).
//  - `<rawValue>.root` on the routed detail view (applied once in
//    ContentView at the routing switch, so a new section is sweepable the
//    moment it is routed).
//  - `error.banner` on every user-facing load-failure banner.
//  - `Resources/Sections.json` — the section list, which this bundle
//    cannot get from the app module. `SectionCatalogTests` (scarfTests)
//    fails the UNIT run if that file drifts from `SidebarSection.allCases`,
//    which is what stops a new section from quietly escaping the sweep.
//
//  ## Isolation
//
//  `ScarfUITestCase` (UITestIsolation.swift) is the base class; the app is
//  built by `makeApp()` and pinned to a per-test throwaway Hermes home. A
//  bare `XCUIApplication()` here would launch Scarf against the
//  developer's real `~/.hermes` and its writes would be permanent.
//
//  ## Capability gating is not failure
//
//  Several rows are gated on the host Hermes version (Bots, Curator,
//  Models, Proxy, Peers, Kanban). On an older host they are legitimately
//  absent from the sidebar. Those are recorded as skipped activities with
//  a printed summary rather than failed — a gate that fails on a correct
//  older host is a gate people disable. A NON-gated section that goes
//  missing is a hard failure.
//

import XCTest

final class SectionSweepUITests: ScarfUITestCase {

    // MARK: - Section catalog

    struct SectionEntry: Decodable {
        let rawValue: String
        /// Needs a live Hermes process or provider key. Swept anyway — we
        /// assert only that the root renders and the app didn't die.
        let live: Bool
        /// Capability-gated: may legitimately have no sidebar row.
        let gated: Bool
    }

    private struct Catalog: Decodable { let sections: [SectionEntry] }

    /// The section list, from the JSON resource bundled with this target.
    ///
    /// Falls back to locating the file through `#filePath` when the
    /// resource is not in the bundle — belt and braces for the case where
    /// the synchronized-folder group has not picked the file up as a
    /// resource. The sweep must never silently sweep zero sections, so an
    /// empty/unreadable catalog throws.
    static func loadSections() throws -> [SectionEntry] {
        let data: Data
        if let url = Bundle(for: SectionSweepUITests.self)
            .url(forResource: "Sections", withExtension: "json") {
            data = try Data(contentsOf: url)
        } else {
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Sections.json")
            data = try Data(contentsOf: source)
        }
        let sections = try JSONDecoder().decode(Catalog.self, from: data).sections
        guard !sections.isEmpty else {
            throw XCTSkip("Sections.json decoded to an empty list — the sweep would assert nothing.")
        }
        return sections
    }

    // MARK: - Sidebar preconditions

    /// Force every sidebar nav section open for the launched app, WITHOUT
    /// touching the developer's saved preference.
    ///
    /// `SidebarSectionCollapseStore` collapses Configure and Manage by
    /// default and persists the user's choice in `UserDefaults.standard` —
    /// a store `SCARF_HERMES_HOME` does not isolate. So the sweep faced
    /// two problems: what is expanded depends on whose Mac this is, and
    /// clicking headers open (`toggle` → `defaults.set`) would REWRITE the
    /// developer's own sidebar state as a side effect of running the gate.
    ///
    /// `-<key> <value>` launch arguments land in `NSArgumentDomain`, which
    /// out-ranks the persisted domain and is never written back — so the
    /// app under test sees every section expanded, nothing is persisted,
    /// and the developer's sidebar is exactly as they left it. `1`/`0`
    /// parse to an `NSNumber` that bridges to the `Bool` the store reads
    /// via `object(forKey:) as? Bool`.
    static let sidebarSectionTitles = ["Monitor", "Bots", "Interact", "Configure", "Manage"]

    static var expandedSidebarLaunchArguments: [String] {
        sidebarSectionTitles.flatMap { ["-sidebar.section.collapsed.\($0)", "0"] }
    }

    // MARK: - The sweep

    /// One launch, every section. Kept as a single test method rather than
    /// one test per section on purpose: launching Scarf ~28 times would
    /// dominate the runtime of the Smoke plan and buy nothing — a section
    /// that only breaks after another section has been visited is a bug we
    /// WANT this test to catch. Per-section attribution comes from
    /// `XCTContext.runActivity`, so the result bundle still shows which
    /// section failed and carries its screenshot.
    @MainActor
    func testEverySectionRenders() throws {
        let sections = try Self.loadSections()

        let app = makeApp(extraLaunchArguments: Self.expandedSidebarLaunchArguments)
        launchAndSurface(app)
        defer { gracefulQuit(app) }

        // Belt to the launch arguments' braces: if a title is ever added
        // to the sidebar without being listed above, this still opens it.
        expandAllSidebarSections(app)

        var missing: [String] = []
        var skippedGated: [String] = []
        var erroring: [String] = []

        for section in sections {
            XCTContext.runActivity(named: "Section: \(section.rawValue)") { _ in
                let row = app.descendants(matching: .any)
                    .matching(identifier: "sidebar.section.\(section.rawValue)")
                    .firstMatch

                guard row.waitForExistence(timeout: 5) else {
                    if section.gated {
                        skippedGated.append(section.rawValue)
                    } else {
                        missing.append(section.rawValue)
                        XCTFail("sidebar.section.\(section.rawValue) is missing and the section is not capability-gated.")
                    }
                    return
                }

                row.click()

                let root = app.descendants(matching: .any)
                    .matching(identifier: "\(section.rawValue).root")
                    .firstMatch
                // Generous: a section's `.task` may do a transport read on
                // first entry, and Chat/Gateway/Proxy spawn processes.
                let rendered = root.waitForExistence(timeout: 20)

                attachScreenshot(app, named: section.rawValue, keepAlways: !rendered)

                XCTAssertTrue(
                    rendered,
                    "\(section.rawValue).root never appeared after clicking its sidebar row — the section didn't render."
                )
                guard rendered else { return }

                // A banner is a rendered-but-broken section. Not a wait:
                // we want "is one on screen NOW", and waiting for a
                // negative would add 28 × timeout to the run.
                let banner = app.descendants(matching: .any)
                    .matching(identifier: "error.banner")
                    .firstMatch
                if banner.exists {
                    erroring.append(section.rawValue)
                    attachScreenshot(app, named: "\(section.rawValue) — error banner", keepAlways: true)
                    XCTFail("\(section.rawValue) rendered with an error.banner on screen: \(banner.label)")
                }

                // The app is still alive — a section that took the process
                // down would otherwise surface as a confusing cascade of
                // failures on every LATER section.
                XCTAssertNotEqual(
                    app.state, .notRunning,
                    "Scarf terminated while showing \(section.rawValue)."
                )
            }
        }

        // One readable summary line; the per-section detail is in the
        // activities above.
        print("""
        [SectionSweep] swept \(sections.count) sections \
        — missing(non-gated): \(missing.isEmpty ? "none" : missing.joined(separator: ", ")) \
        — absent(capability-gated, OK): \(skippedGated.isEmpty ? "none" : skippedGated.joined(separator: ", ")) \
        — error banners: \(erroring.isEmpty ? "none" : erroring.joined(separator: ", "))
        """)
    }

    // MARK: - Helpers

    /// Click open every collapsed sidebar nav section.
    ///
    /// The headers carry `sidebar.sectionHeader.<Title>` and speak their
    /// state as the accessibility VALUE ("collapsed"/"expanded"), which is
    /// what we read here — cheaper and less brittle than inferring it from
    /// whether the rows beneath happen to be hittable.
    private func expandAllSidebarSections(_ app: XCUIApplication) {
        let headers = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.sectionHeader.'"))
        guard headers.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("No sidebar section headers found — did the sidebar render at all?")
            return
        }
        for header in headers.allElementsBoundByIndex where header.exists {
            if (header.value as? String) == "collapsed" {
                header.click()
            }
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String, keepAlways: Bool) {
        let shot = XCTAttachment(screenshot: windowScreenshot(app))
        shot.name = name
        // Keep only what someone would want to look at: a green sweep
        // otherwise writes ~28 full-screen PNGs into every result bundle.
        shot.lifetime = keepAlways ? .keepAlways : .deleteOnSuccess
        add(shot)
    }
}
