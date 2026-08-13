import SwiftUI
import ScarfCore
import ScarfDesign

/// Compact NxM grid of colored cells, one per service / item. Denser than
/// `list` for monitoring dashboards with 12+ entities. Uses the same
/// `ListItemStatus` vocabulary as the list widget so colors stay consistent.
struct StatusGridWidgetView: View {
    let widget: DashboardWidget

    private var cells: [StatusGridCell] { widget.cells ?? [] }

    /// Auto-fit columns when not specified: aim for ~6 cells per row, capped
    /// at 12, floored at 1. Ensures both 8-cell and 36-cell grids look ok.
    private var columnCount: Int {
        if let n = widget.gridColumns, n > 0 { return min(20, n) }
        let count = cells.count
        if count <= 4 { return max(1, count) }
        if count <= 12 { return 6 }
        if count <= 24 { return 8 }
        return 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.secondary)
                    .scarfStyle(.caption)
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(cells.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if cells.isEmpty {
                Text("No cells.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount),
                    spacing: 4
                ) {
                    ForEach(cells) { cell in
                        StatusGridCellView(cell: cell)
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

private struct StatusGridCellView: View {
    let cell: StatusGridCell

    private var typedStatus: ListItemStatus { ListItemStatus(raw: cell.status) ?? .neutral }

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(typedStatus.tint.opacity(0.85))
                .frame(height: 18)
            Text(cell.label)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .help(cell.tooltip ?? cell.label + (cell.status.map { " — \($0)" } ?? ""))
    }
}
