import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS dashboard layout. ScrollView of sections; each section is a
/// `LazyVGrid` whose column count is clamped to the device's
/// `horizontalSizeClass`. iPhone (compact) → 1 column. iPad / split-
/// view (regular) → 2 columns max, even when the dashboard JSON asks
/// for 3 (3-column on a 13" iPad portrait still cramps individual
/// widgets).
///
/// Webview widgets in card mode render inline like any other widget.
/// The full-canvas Site tab is rendered separately by `ProjectSiteView`
/// and excluded from this grid by `ProjectDetailView` before passing
/// the dashboard down — so we don't filter here.
struct DashboardWidgetsView: View {
    let dashboard: ProjectDashboard

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let description = dashboard.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .padding(.horizontal)
                }
                ForEach(dashboard.sections) { section in
                    sectionView(section)
                }
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DashboardSection) -> some View {
        // Filter out webview widgets — those are rendered full-screen
        // in the Site tab instead. Matches Mac DashboardSectionView.
        let displayWidgets = section.widgets.filter { $0.type != "webview" }
        if !displayWidgets.isEmpty {
            let cols = columnCount(for: section)
            VStack(alignment: .leading, spacing: 8) {
                if !section.title.isEmpty {
                    Text(section.title)
                        .font(.headline)
                        .padding(.horizontal)
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols),
                    spacing: 10
                ) {
                    ForEach(displayWidgets) { widget in
                        WidgetView(widget: widget)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Cap the requested column count by available width. Compact
    /// (iPhone) is always 1; regular (iPad / large split-view) caps at
    /// 2 to avoid a 3-up layout that crowds chart + table widgets.
    private func columnCount(for section: DashboardSection) -> Int {
        switch hSizeClass {
        case .compact: return 1
        case .regular: return min(section.columnCount, 2)
        default: return 1
        }
    }
}

/// Widget-type dispatcher. Mirrors Mac's `WidgetView` switch in
/// `scarf/Features/Projects/Views/ProjectsView.swift`. Unknown types
/// fall through to a small placeholder so a manifest from a future
/// schema version doesn't crash the UI.
struct WidgetView: View {
    let widget: DashboardWidget

    var body: some View {
        switch widget.type {
        case "stat":
            StatWidgetView(widget: widget)
        case "progress":
            ProgressWidgetView(widget: widget)
        case "text":
            TextWidgetView(widget: widget)
        case "table":
            TableWidgetView(widget: widget)
        case "chart":
            ChartWidgetView(widget: widget)
        case "list":
            ListWidgetView(widget: widget)
        case "webview":
            WebviewWidgetView(widget: widget)
        default:
            unsupportedView
        }
    }

    private var unsupportedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(widget.title, systemImage: "questionmark.app.dashed")
                .font(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text("Widget type \"\(widget.type)\" isn't supported in this version of Scarf yet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
