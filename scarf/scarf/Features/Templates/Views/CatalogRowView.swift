import ScarfCore
import ScarfDesign
import SwiftUI

/// One row in the catalog list. Renders an SF Symbol icon (category-coded),
/// the template name + version, a one-line description, tag chips, and
/// the install-state badge. Tapping a row pushes `CatalogDetailView`;
/// the row itself doesn't own that navigation — `CatalogView` handles
/// it via `NavigationLink` wrapping.
struct CatalogRowView: View {
    let entry: CatalogEntry
    let installState: InstalledTemplatesIndex.InstallState

    var body: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            categoryIcon
                .font(.system(size: 22))
                .foregroundStyle(ScarfColor.accent)
                .frame(width: 32, height: 32, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                    Text(entry.name)
                        .scarfStyle(.body)
                        .fontWeight(.semibold)
                    Text("v\(entry.version)")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer(minLength: 0)
                    installStateBadge
                }
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(2)
                }
                if !entry.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(entry.tags.prefix(4), id: \.self) { tag in
                            ScarfBadge(tag, kind: .neutral)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, ScarfSpace.s2)
        .accessibilityIdentifier("catalog.row.\(entry.detailSlug ?? entry.id)")
    }

    @ViewBuilder
    private var installStateBadge: some View {
        switch installState {
        case .notInstalled:
            // Default state — no badge, keeps the row visually quiet.
            EmptyView()
        case .installed:
            ScarfBadge("Installed", kind: .success)
        case .updateAvailable(_, let catalogVersion):
            ScarfBadge("Update v\(catalogVersion)", kind: .warning)
        }
    }

    /// Map the freeform `category` string to an SF Symbol. Anything we
    /// haven't seen falls through to a generic puzzle-piece. Keep
    /// in sync with `availableCategories` from the live catalog —
    /// `tools/build-catalog.py` doesn't constrain the field.
    private var categoryIcon: Image {
        switch entry.category?.lowercased() ?? "" {
        case "monitoring": return Image(systemName: "checkmark.shield")
        case "news":       return Image(systemName: "newspaper")
        case "dev":        return Image(systemName: "hammer")
        case "ops":        return Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        case "personal":   return Image(systemName: "person.crop.circle")
        case "finance":    return Image(systemName: "chart.line.uptrend.xyaxis")
        default:           return Image(systemName: "shippingbox")
        }
    }
}
