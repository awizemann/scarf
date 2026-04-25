import SwiftUI
import ScarfCore
import ScarfDesign

struct TableWidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(widget.title)
                .scarfStyle(.caption)
                .foregroundStyle(.secondary)
            if let columns = widget.columns, let rows = widget.rows {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(columns, id: \.self) { col in
                            Text(col)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.callout)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }
}
