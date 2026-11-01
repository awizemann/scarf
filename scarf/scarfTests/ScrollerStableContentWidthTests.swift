import AppKit
import SwiftUI
import XCTest
@testable import scarf

/// The chat list hang: with legacy scrollers, content whose height depends on
/// its width can flip the scroller forever. The modifier must give the content
/// the same width whether or not the scroller shows.
@MainActor
final class ScrollerStableContentWidthTests: XCTestCase {
    private final class Widths { var seen: [CGFloat] = [] }

    private struct Reporter: View {
        let widths: Widths
        let height: CGFloat
        var body: some View {
            Color.clear
                .frame(height: height)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.seen.append($0) }
        }
    }

    private struct Host: View {
        let widths: Widths
        let height: CGFloat
        let stable: Bool
        @State private var viewport: CGFloat?
        var body: some View {
            ScrollView {
                if stable {
                    Reporter(widths: widths, height: height)
                        .modifier(ScrollerStableContentWidth(viewportWidth: viewport))
                } else {
                    Reporter(widths: widths, height: height)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        }
    }

    /// The width the content was last placed at, with this content height.
    private func settledWidth(height: CGFloat, stable: Bool) throws -> CGFloat {
        let widths = Widths()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 330, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(widths: widths, height: height, stable: stable))
        window.orderFrontRegardless()
        for _ in 0..<20 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        window.orderOut(nil)
        return try XCTUnwrap(widths.seen.last)
    }

    func testContentWidthIgnoresTheScroller() throws {
        try XCTSkipUnless(NSScroller.preferredScrollerStyle == .legacy,
                          "Needs legacy scrollers: run with -AppleShowScrollBars Always (overlay scrollers take no width).")
        XCTAssertNotEqual(try settledWidth(height: 100, stable: false), try settledWidth(height: 900, stable: false),
                          "Without the modifier the scroller should narrow the content, or this test proves nothing.")
        XCTAssertEqual(try settledWidth(height: 100, stable: true), try settledWidth(height: 900, stable: true))
    }

    func testOverlayScrollersReserveNothing() {
        XCTAssertNil(ScrollerStableContentWidth.contentWidth(viewportWidth: 330, style: .overlay))
        XCTAssertNil(ScrollerStableContentWidth.contentWidth(viewportWidth: nil, style: .legacy))
        XCTAssertEqual(ScrollerStableContentWidth.contentWidth(viewportWidth: 330, style: .legacy),
                       330 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }
}
