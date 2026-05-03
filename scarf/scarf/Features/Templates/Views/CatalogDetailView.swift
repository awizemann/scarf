import ScarfCore
import ScarfDesign
import SwiftUI

/// Detail page for a single catalog entry. Surfaces what's already in
/// `catalog.json` — name, version, author, description, contents
/// claim, config schema preview. Deliberately does NOT fetch a
/// separate README from the network; the catalog's `description` is
/// the single source of truth at v2.8 to keep the sheet snappy and
/// offline-friendly.
struct CatalogDetailView: View {
    let entry: CatalogEntry
    let installState: InstalledTemplatesIndex.InstallState
    let onInstall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                header
                Divider()
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .scarfStyle(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(entry.tags, id: \.self) { tag in
                            ScarfBadge(tag, kind: .neutral)
                        }
                    }
                }
                contentsBlock
                if let config = entry.config, !config.fields.isEmpty {
                    configBlock(config: config)
                }
                Spacer(minLength: ScarfSpace.s4)
                installRow
            }
            .padding(ScarfSpace.s5)
        }
        .navigationTitle(entry.name)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Text(entry.name)
                    .scarfStyle(.title2)
                    .fontWeight(.semibold)
                Text("v\(entry.version)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer(minLength: 0)
                installStateBadge
            }
            HStack(spacing: ScarfSpace.s2) {
                Text("by \(entry.author.name)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                if let category = entry.category, !category.isEmpty {
                    Text("·")
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text(category.capitalized)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
        }
    }

    @ViewBuilder
    private var contentsBlock: some View {
        if let contents = entry.contents {
            VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                Text("What's inside")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                VStack(alignment: .leading, spacing: 4) {
                    if contents.dashboard == true { contentRow(icon: "rectangle.grid.2x2", text: "Dashboard") }
                    if contents.agentsMd == true { contentRow(icon: "doc.text", text: "AGENTS.md (cross-agent contract)") }
                    if let cron = contents.cron, cron > 0 {
                        contentRow(icon: "clock.badge.checkmark", text: "\(cron) cron job\(cron == 1 ? "" : "s") (paused on install)")
                    }
                    if let config = contents.config, config > 0 {
                        contentRow(icon: "slider.horizontal.3", text: "\(config) configuration field\(config == 1 ? "" : "s")")
                    }
                    if contents.memory == true {
                        contentRow(icon: "memorychip", text: "Memory appendix")
                    }
                    if let skills = contents.skills, !skills.isEmpty {
                        contentRow(icon: "wand.and.rays", text: "\(skills.count) skill\(skills.count == 1 ? "" : "s"): \(skills.joined(separator: ", "))")
                    }
                }
            }
        }
    }

    private func configBlock(config: TemplateConfigSchema) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            Text("Configuration")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(config.fields, id: \.key) { field in
                    HStack(alignment: .top, spacing: ScarfSpace.s2) {
                        Image(systemName: field.type == .secret ? "lock.shield" : "circle")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.label)
                                .scarfStyle(.body)
                            if let description = field.description, !description.isEmpty {
                                Text(description)
                                    .scarfStyle(.caption)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if let recommendation = config.modelRecommendation {
                Text("Recommended model: \(recommendation.preferred). \(recommendation.rationale ?? "")")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .padding(.top, 2)
            }
        }
    }

    private var installRow: some View {
        HStack {
            Spacer()
            Button(installButtonLabel) {
                onInstall()
            }
            .buttonStyle(ScarfPrimaryButton())
            .accessibilityIdentifier("catalogDetail.installButton")
        }
    }

    // MARK: - Helpers

    private func contentRow(icon: String, text: String) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: icon)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 16)
            Text(text)
                .scarfStyle(.body)
        }
    }

    private var installButtonLabel: String {
        switch installState {
        case .notInstalled:        return "Install"
        case .installed:           return "Reinstall"
        case .updateAvailable:     return "Update"
        }
    }

    @ViewBuilder
    private var installStateBadge: some View {
        switch installState {
        case .notInstalled:
            EmptyView()
        case .installed(let version):
            ScarfBadge("Installed v\(version)", kind: .success)
        case .updateAvailable(let installedVersion, _):
            ScarfBadge("v\(installedVersion) installed", kind: .warning)
        }
    }
}
