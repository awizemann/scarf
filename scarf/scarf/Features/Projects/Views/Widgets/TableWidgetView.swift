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
                                // `Grid` has no native table semantics, so a
                                // header row read exactly like a data row —
                                // mark it so VoiceOver announces "header".
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                                Text(cell)
                                    .font(.callout)
                                    // Each cell speaks with its column name,
                                    // so cross-referencing a row doesn't
                                    // require holding the header row in
                                    // memory while VoiceOver walks the grid.
                                    .accessibilityLabel(
                                        Text(columns.indices.contains(colIndex)
                                             ? "\(columns[colIndex]): \(cell)"
                                             : cell)
                                    )
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Row \(rowIndex + 1)"))
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
