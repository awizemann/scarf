import SwiftUI
import ScarfCore

struct TextWidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(widget.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let content = widget.content {
                if widget.format == "markdown" {
                    // SwiftUI's built-in inline markdown via AttributedString.
                    // Doesn't support block elements (lists, tables) the way
                    // Mac's MarkdownContentView does, but covers the common
                    // dashboard cases (bold, italic, links, inline code).
                    Text(attributed(content))
                        .font(.callout)
                } else {
                    Text(content)
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}
