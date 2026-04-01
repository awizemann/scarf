import SwiftUI

struct TextWidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(widget.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let content = widget.content {
                if widget.format == "markdown",
                   let attributed = try? AttributedString(markdown: content) {
                    Text(attributed)
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
}
