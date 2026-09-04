import SwiftUI
import ScarfCore
import ScarfDesign
import Charts

// Flattened data point for Charts to avoid complex nested generic inference
private struct PlottablePoint: Identifiable {
    let id = UUID()
    let seriesName: String
    let x: String
    let y: Double
    let color: Color
}

struct ChartWidgetView: View {
    let widget: DashboardWidget

    private var points: [PlottablePoint] {
        guard let series = widget.series else { return [] }
        return series.flatMap { s in
            let color = parseColor(s.color)
            return s.data.map { d in
                PlottablePoint(seriesName: s.name, x: d.x, y: d.y, color: color)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(widget.title)
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            chartContent
                .frame(height: 150)
                // Charts (pie especially) are color-only for everyone, and
                // Swift Charts marks aren't individually voiced by default.
                // Group the plot into one element and speak every point as
                // its value, so VoiceOver gets the data, not just "chart".
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(widget.title))
                .accessibilityValue(Text(accessibilitySummary))
                .accessibilityChartDescriptor(self)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    @ViewBuilder
    private var chartContent: some View {
        switch widget.chartType {
        case "pie":
            pieChart
        case "bar":
            barChart
        default:
            lineChart
        }
    }

    private var lineChart: some View {
        Chart(points) { point in
            LineMark(
                x: .value("X", point.x),
                y: .value("Y", point.y)
            )
            .foregroundStyle(point.color)
            .symbol(by: .value("Series", point.seriesName))
        }
    }

    private var barChart: some View {
        Chart(points) { point in
            BarMark(
                x: .value("X", point.x),
                y: .value("Y", point.y)
            )
            .foregroundStyle(point.color)
        }
    }

    private var pieChart: some View {
        Chart(points) { point in
            SectorMark(
                angle: .value(point.x, point.y),
                innerRadius: .ratio(0.5)
            )
            .foregroundStyle(point.color)
        }
    }

    /// One-line fallback read for anything that doesn't route through the
    /// chart descriptor (e.g. a quick VoiceOver rotor pass).
    private var accessibilitySummary: String {
        guard !points.isEmpty else { return String(localized: "No data.") }
        return points
            .map { "\($0.x): \(formatted($0.y))" }
            .joined(separator: ", ")
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}

extension ChartWidgetView: AXChartDescriptorRepresentable {
    /// Per-mark accessibility values for the chart's real content — the pie
    /// chart in particular was color-only for every VoiceOver user, not just
    /// the colorblind ones `.foregroundStyle` alone would already fail.
    func makeChartDescriptor() -> AXChartDescriptor {
        let xValues = points.map(\.x)
        let yValues = points.map(\.y)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Category",
            range: 0...Double(max(1, xValues.count - 1)),
            gridlinePositions: []
        ) { index in xValues.indices.contains(Int(index)) ? xValues[Int(index)] : "" }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Value",
            range: (yValues.min() ?? 0)...(yValues.max() ?? 1),
            gridlinePositions: []
        ) { value in formatted(value) }

        let series = AXDataSeriesDescriptor(
            name: widget.title,
            isContinuous: false,
            dataPoints: points.enumerated().map { index, point in
                AXDataPoint(x: Double(index), y: point.y, additionalValues: [], label: point.x)
            }
        )

        return AXChartDescriptor(
            title: widget.title,
            summary: accessibilitySummary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series]
        )
    }
}
