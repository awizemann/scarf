import SwiftUI

/// Trailing slide-in surface for mini-apps.
///
/// **Why not SwiftUI `.inspector`.** `.inspector` is a real layout *column*,
/// so adding it increases the content's minimum width — and under the app's
/// `.windowResizability(.contentMinSize)` the WINDOW grows to fit it (it
/// "slides wider," sometimes to full screen). This is an **overlay** instead:
/// the window keeps its size and the mini-app covers the right portion of the
/// existing chrome. The empty left strip is non-hit-testing, so the sidebar +
/// cockpit stay interactive (an inspector is non-modal). Drag the left edge to
/// resize; the hosted content (`MiniAppLaunchHost`) owns its Close.
struct MiniAppInspectorSurface<Content: View>: View {
    @ViewBuilder var content: Content

    /// Current panel width; `nil` until first layout → defaults to ~74% of
    /// the available width.
    @State private var width: CGFloat?
    /// Width captured at the start of a resize drag, so the delta is applied
    /// once rather than cumulatively.
    @State private var dragStart: CGFloat?

    private let defaultFraction: CGFloat = 0.74
    private let minWidth: CGFloat = 420
    /// Always leave at least this much for the sidebar + a cockpit sliver.
    private let leftReserve: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let maxWidth = max(minWidth + 1, total - leftReserve)
            let w = min(max(width ?? total * defaultFraction, minWidth), maxWidth)
            HStack(spacing: 0) {
                // Left strip: invisible AND click-through, so the cockpit
                // behind it stays usable while the mini-app is open.
                Color.clear
                    .allowsHitTesting(false)
                resizeHandle(current: w)
                content
                    .frame(width: w)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))   // opaque — cockpit must not bleed through
                    .overlay(alignment: .leading) {
                        Rectangle().frame(width: 1).foregroundStyle(Color(nsColor: .separatorColor))
                    }
                    .shadow(color: .black.opacity(0.18), radius: 14, x: -3, y: 0)
                    // Mouse/keyboard users can still reach the sidebar and
                    // cockpit behind this panel (the doc comment above
                    // explains why — it's an overlay, not a real `.inspector`
                    // column). But nothing told VoiceOver the panel had just
                    // appeared and mattered most: it had equal standing with
                    // the content behind it, so VO could wander off into a
                    // half-obscured cockpit. `.isModal` scopes VO navigation
                    // to the panel while it's open, which is the closer match
                    // to what a sighted user's attention actually does.
                    .accessibilityAddTraits(.isModal)
                    .accessibilitySortPriority(1)
            }
        }
    }

    private func resizeHandle(current: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = current }
                        // Dragging the handle LEFT (negative translation)
                        // widens the panel.
                        width = (dragStart ?? current) - value.translation.width
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
