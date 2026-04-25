import SwiftUI
import ScarfCore
import ScarfDesign

struct TextWidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(widget.title)
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            if let content = widget.content {
                if widget.format == "markdown" {
                    MarkdownContentView(content: content)
                } else {
                    Text(content)
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }
}
