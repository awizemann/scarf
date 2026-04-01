import SwiftUI

struct ListWidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let icon = widget.icon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text(widget.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let items = widget.items {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon(item.status))
                            .font(.caption2)
                            .foregroundStyle(statusColor(item.status))
                        Text(item.text)
                            .font(.callout)
                            .strikethrough(item.status == "done")
                            .foregroundStyle(item.status == "done" ? .secondary : .primary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusIcon(_ status: String?) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "active": return "circle.inset.filled"
        case "pending": return "circle"
        default: return "circle"
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "done": return .green
        case "active": return .blue
        default: return .secondary
        }
    }
}
