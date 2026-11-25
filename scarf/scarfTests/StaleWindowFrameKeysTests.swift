import Testing
import Foundation
@testable import scarf

/// `StaleWindowFrameKeys` picks out only SwiftUI's own per-build frame keys —
/// never Scarf's own frame/sidebar keys or AppKit-named ones it doesn't own.
@Suite struct StaleWindowFrameKeysTests {
    @Test func selectsOnlySwiftUISavedFrames() {
        let swiftUIWindow = "NSWindow Frame SwiftUI.WindowGroup<SwiftUI.PresentedWindowContent<Foundation.UUID, unknown context at $10a2c>>-AppWindow-1"
        let swiftUISplit = "NSSplitView Subview Frames SwiftUI.ModifiedContent<unknown context at $10b3f>, SidebarNavigationSplitView"
        let keys = [
            swiftUIWindow,
            swiftUISplit,
            "ScarfWindowFrame.Scarf.Window.00000000-0000-0000-0000-000000000001",
            "NSSplitView Subview Frames ScarfMainSidebar.00000000-0000-0000-0000-000000000001",
            "NSWindow Frame SUUpdateAlert2",
            "scarf.hermesVersionLines.migrated",
        ]
        #expect(StaleWindowFrameKeys.stale(in: keys) == [swiftUIWindow, swiftUISplit])
    }

    @Test func emptyWhenNothingStale() {
        #expect(StaleWindowFrameKeys.stale(in: ["ScarfWindowFrame.x", "NSWindow Frame Other"]).isEmpty)
    }
}
