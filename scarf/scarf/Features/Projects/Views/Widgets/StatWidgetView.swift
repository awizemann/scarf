import SwiftUI

struct StatWidgetView: View {
    let widget: DashboardWidget

    private var widgetColor: Color {
        parseColor(widget.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let icon = widget.icon {
                    Image(systemName: icon)
                        .foregroundStyle(widgetColor)
                        .font(.caption)
                }
                Text(widget.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let value = widget.value {
                Text(value.displayString)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
            }
            if let subtitle = widget.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(widgetColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
