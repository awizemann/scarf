import SwiftUI
import AppKit

/// Shared user-resizable side-column behavior for Mac master-detail /
/// multi-pane layouts (chat sessions list, bots roster, inspector).
///
/// Why not `HSplitView`: it offers drag-resizing but forgets the divider
/// position on every relaunch and fights conditional show/hide
/// transitions. This modifier gives a pane a fixed, *persisted* width
/// (per-column `AppStorage` key) plus a drag handle on the chosen edge,
/// so the pane composes inside a plain `HStack` next to panes that flex.
///
/// Feedback-loop safety: the drag applies its delta against the width
/// captured at drag start (never the live value), and the width is
/// clamped both when read (restoration sanity — a bad persisted value
/// can never crush the neighboring pane) and when written.
struct ResizableColumn: ViewModifier {
    /// Persisted width. `AppStorage` with a dynamic key — one key per column.
    @AppStorage private var width: Double
    @State private var dragStartWidth: Double?

    private let minWidth: Double
    private let maxWidth: Double
    private let handleEdge: HorizontalEdge

    init(key: String, defaultWidth: Double, minWidth: Double, maxWidth: Double, handleEdge: HorizontalEdge) {
        self._width = AppStorage(wrappedValue: defaultWidth, key)
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.handleEdge = handleEdge
    }

    private var clampedWidth: Double { min(max(width, minWidth), maxWidth) }

    func body(content: Content) -> some View {
        content
            .frame(width: clampedWidth)
            .overlay(alignment: handleEdge == .trailing ? .trailing : .leading) {
                handle
            }
    }

    /// Invisible grab strip hugging the resizable edge. Sits inside the
    /// column so it never shifts layout; the visible divider stays the
    /// call site's concern.
    private var handle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                // Global coordinate space: the handle itself moves as the
                // column resizes, so a `.local` translation would read
                // ~0 mid-drag and stall the resize.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = clampedWidth }
                        let base = dragStartWidth ?? clampedWidth
                        // Trailing handle: dragging right widens. Leading
                        // handle (column on the window's right): dragging
                        // left widens.
                        let proposed = handleEdge == .trailing
                            ? base + value.translation.width
                            : base - value.translation.width
                        width = min(max(proposed, minWidth), maxWidth)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

extension View {
    /// Makes this pane a user-resizable fixed-width column whose width
    /// persists under `key`. `handleEdge` is the draggable edge —
    /// `.trailing` for a left-side column, `.leading` for a right-side one.
    func resizableColumn(
        key: String,
        defaultWidth: Double,
        minWidth: Double,
        maxWidth: Double,
        handleEdge: HorizontalEdge = .trailing
    ) -> some View {
        modifier(ResizableColumn(
            key: key,
            defaultWidth: defaultWidth,
            minWidth: minWidth,
            maxWidth: maxWidth,
            handleEdge: handleEdge
        ))
    }
}
