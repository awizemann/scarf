import SwiftUI
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
                .font(.caption)
                .foregroundStyle(.secondary)
            chartContent
                .frame(height: 150)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
}
