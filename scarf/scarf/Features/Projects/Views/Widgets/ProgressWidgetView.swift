import SwiftUI

struct ProgressWidgetView: View {
    let widget: DashboardWidget

    private var progressValue: Double {
        switch widget.value {
        case .number(let n): return n
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(widget.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progressValue) {
                if let label = widget.label {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(parseColor(widget.color))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
