import SwiftUI

/// Minimal flow layout — wraps subviews onto multiple lines when they
/// overflow the available width. Built on the Layout protocol; no
/// third-party dependency.
///
/// Used for chip rows that need to wrap on iPhone-narrow screens —
/// SKILL.md frontmatter chips (`allowed_tools` / `related_skills` /
/// `dependencies`) on the Skills detail view, and any future place
/// that wants pill-shaped wrapping content.
///
/// Promoted from the deleted `iOS Skills/SkillsListView.swift`'s
/// inline definition during the v2.5 iOS-design merge so multiple
/// views can share it without duplicating ~30 lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let maxWidth = proposal.width else { return .zero }
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
