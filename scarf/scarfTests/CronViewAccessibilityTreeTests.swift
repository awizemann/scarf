import XCTest
import SwiftUI
import AppKit
@testable import scarf
import ScarfCore

/// t-0fb3b91f — `CronView`'s detail pane was unreachable: the job rows
/// took no click (an unselected row's background is `Color.clear`, so a
/// `.plain` Button's hit area was its glyphs only), and the `HSplitView`
/// whose two `minWidth`s summed to 720 pt overflowed — and a clipped
/// SwiftUI subtree is absent from the accessibility tree, for VoiceOver
/// exactly as much as for XCUITest.
///
/// This renders the REAL view in an `NSHostingView` and walks AppKit's
/// accessibility tree, so the regression is caught without the UI gate
/// (which can only be run alone, on a Mac nobody is touching).
///
/// `accessibilityEnhancedUserInterface` is the switch that makes AppKit
/// build the tree at all — without it a hosted SwiftUI view reports zero
/// accessibility children and every assertion here would be vacuous
/// (`testProbeItselfWorks` guards exactly that).
@MainActor
final class CronViewAccessibilityTreeTests: XCTestCase {

    // MARK: - Tree walking

    private struct AXNode {
        let role: String
        let identifier: String
        let label: String
        let value: String
        let frame: NSRect
    }

    private func nodes(of element: Any, depth: Int = 0, into found: inout [AXNode]) {
        guard depth < 12 else { return }
        let obj = element as AnyObject
        found.append(AXNode(
            role: (obj.accessibilityRole?() ?? NSAccessibility.Role(rawValue: "")).rawValue,
            identifier: obj.accessibilityIdentifier?() ?? "",
            label: obj.accessibilityLabel?() ?? "",
            value: String(describing: (obj as? NSObject)?.value(forKey: "accessibilityValue") ?? ""),
            frame: obj.accessibilityFrame?() ?? .zero
        ))
        for child in obj.accessibilityChildren?() ?? [] {
            nodes(of: child, depth: depth + 1, into: &found)
        }
    }

    private func axTree(of view: some View, width: CGFloat) -> [AXNode] {
        // Only an accessibility CLIENT normally flips this; a test process
        // has none, so ask for it directly.
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        var found: [AXNode] = []
        nodes(of: host, into: &found)
        window.orderOut(nil)
        return found
    }

    // MARK: - Fixtures

    private func job(id: String, name: String, enabled: Bool) -> HermesCronJob {
        HermesCronJob(
            id: id,
            name: name,
            prompt: "ok",
            schedule: CronSchedule(kind: "interval", runAt: nil, display: "every 120m", expression: nil, minutes: 120),
            enabled: enabled,
            state: "scheduled"
        )
    }

    /// A view model that will not talk to a Hermes host: `load()` is
    /// driven off `onAppear`, so the jobs are re-read from whatever home
    /// the test process sees. The assertions below only ever look for the
    /// pane's own identifiers, never for a specific row.
    private func makeView(selected: Bool) -> some View {
        let viewModel = CronViewModel(context: .local)
        viewModel.jobs = [
            job(id: "job-a", name: "Nightly digest", enabled: true),
            job(id: "job-b", name: "Weekly sweep", enabled: false)
        ]
        if selected { viewModel.selectedJob = viewModel.jobs[0] }
        return CronView(viewModel: viewModel)
            // A throwaway tracker, not the process-global `Analytics` slot:
            // building an `AppCoordinator` emits `section_viewed`, and with no
            // tracker of its own that event lands in whatever another suite
            // installed — which is exactly the equality
            // `AnalyticsFeatureUsageEventsTests` asserts (round-5 P48b).
            .environment(AppCoordinator(usageTracker: NoopUsageTracker()))
            .environment(HermesFileWatcher())
    }

    // MARK: - Tests

    /// The probe's own precondition: a hosted SwiftUI view really does
    /// publish an accessibility tree here. Without this, a regression in
    /// the harness would read as "everything passes".
    func testProbeItselfWorks() {
        let tree = axTree(of: makeView(selected: false), width: 1200)
        XCTAssertTrue(
            tree.contains { $0.identifier == "cron.newJob" },
            "The probe found no cron.newJob, so it is not reading a real accessibility tree: \(tree.map(\.role))"
        )
    }

    /// The detail pane must be in the tree at every width the app can
    /// render, including one far narrower than the old HSplitView's
    /// 320 + 400 minimums.
    func testDetailPaneIsInTheAccessibilityTreeAtEveryWidth() {
        for width in [560.0, 720.0, 1200.0] {
            let tree = axTree(of: makeView(selected: true), width: width)
            for identifier in ["cron.detail.state", "cron.detail.pauseToggle", "cron.detail.delete"] {
                XCTAssertTrue(
                    tree.contains { $0.identifier == identifier },
                    "\(identifier) is missing from the accessibility tree at \(width) pt — the detail pane is clipped again."
                )
            }
        }
    }

    /// With nothing selected the pane still has to exist: the placeholder
    /// is what a VoiceOver user lands on.
    func testPlaceholderIsInTheAccessibilityTree() {
        let tree = axTree(of: makeView(selected: false), width: 720)
        XCTAssertTrue(
            tree.contains { $0.value.contains("Select a cron job") },
            "The 'Select a cron job' placeholder is not in the accessibility tree."
        )
    }

    /// Rows are buttons, named name-first/state-after, and their hit area
    /// is the WHOLE row — a click in the middle of a row is what both a
    /// mouse user and XCUITest do.
    func testRowsAreNamedButtonsSpanningTheWholeRow() {
        let tree = axTree(of: makeView(selected: false), width: 1200)
        let rows = tree.filter { $0.identifier.hasPrefix("cron.row.") }
        XCTAssertFalse(rows.isEmpty, "No cron.row.* elements in the tree at all.")
        for row in rows {
            XCTAssertEqual(row.role, NSAccessibilityRoleDescription.button, "cron row \(row.identifier) is not a button.")
            XCTAssertFalse(row.label.isEmpty, "cron row \(row.identifier) has no accessibility label.")
            XCTAssertGreaterThan(row.frame.width, 100, "cron row \(row.identifier) reports a degenerate frame: \(row.frame).")
        }
    }
}

private enum NSAccessibilityRoleDescription {
    static let button = NSAccessibility.Role.button.rawValue
}
