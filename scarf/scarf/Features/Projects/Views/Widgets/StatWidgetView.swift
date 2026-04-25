import SwiftUI
import ScarfCore
import ScarfDesign

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
                        .scarfStyle(.caption)
                }
                Text(widget.title)
                    .scarfStyle(.caption)
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
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }
}
