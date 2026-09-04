import SwiftUI
import ScarfCore
import ScarfDesign

/// Tiny inline trend line drawn under a `stat` widget's value. Pure SwiftUI
/// `Path`, no Swift Charts dependency — stays light enough to render
/// dozens per dashboard without measurable cost.
struct SparklineView: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let span = max(0.0001, maxV - minV)
            let stepX = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let normalized = (v - minV) / span
                    let y = geo.size.height - CGFloat(normalized) * geo.size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(tint.opacity(0.85), lineWidth: 1.2)
        }
        // The trend line was pure `Path` drawing — completely invisible to
        // VoiceOver. Speak the shape as a value instead of the pixels.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trend"))
        .accessibilityValue(Text(trendSummary))
    }

    private var trendSummary: String {
        guard let first = values.first, let last = values.last else { return String(localized: "No data.") }
        if values.count < 2 { return String(localized: "No trend.") }
        let delta = last - first
        if abs(delta) < 0.0001 {
            return String(localized: "Flat, around \(formatted(last)).")
        }
        let direction = delta > 0 ? String(localized: "up") : String(localized: "down")
        return String(localized: "Trending \(direction) from \(formatted(first)) to \(formatted(last)).")
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}

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
            if let sparkline = widget.sparkline, sparkline.count >= 2 {
                SparklineView(values: sparkline, tint: widgetColor)
                    .frame(height: 18)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
        // Ungrouped, VoiceOver walked title / value / subtitle / sparkline
        // as four separate stops. Combine into one stat — title, value, and
        // subtitle read together, and the sparkline's own trend value (set
        // above) folds in as the last fragment.
        .accessibilityElement(children: .combine)
    }
}
