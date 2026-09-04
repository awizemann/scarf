import SwiftUI
import ScarfCore
import ScarfDesign

/// Top-level Projects tab. Lists registered Scarf projects from
/// `~/.hermes/scarf/projects.json`. Folder groupings + archive flags
/// from the v2.3 registry schema are honored — archived projects are
/// hidden, top-level projects render flat, and any non-empty folder
/// labels become a `Section` per folder.
///
/// Read-only on iOS for v2.5 — add / rename / move / archive happens
/// in the Mac app, where the template installer + ConfigEditor live.
/// The empty state copy directs users there.
struct ProjectsListView: View {
    let config: IOSServerConfig

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A2"
    )!

    @State private var projects: [ProjectEntry] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    /// One sentence naming the damage the last registry read had to work
    /// around, or `nil` for a clean read.
    ///
    /// iOS called plain `loadRegistry()` everywhere, which throws the
    /// salvage report away — so a registry that dropped rows, or was
    /// quarantined outright, rendered on the phone as a SHORT LIST with no
    /// banner and nothing to click. The Mac has said this out loud since
    /// Phase 2; the phone now says it too (P7 addendum). Read-only surface,
    /// so it explains and points at the Mac rather than offering a repair.
    @State private var damage: String?
    /// Last value `damage` was announced for. Refresh polls this screen
    /// repeatedly (`.refreshable` / `.task`); without tracking this, an
    /// unchanged damage string would re-announce on every pull-to-refresh
    /// instead of only when it newly appears (Mac `RegistryDamageBanner`
    /// parity — announce on transition, not on every read).
    @State private var lastAnnouncedDamage: String?

    private var serverContext: ServerContext {
        config.toServerContext(id: Self.sharedContextID)
    }

    var body: some View {
        Group {
            if isLoading && projects.isEmpty {
                ProgressView("Loading projects…")
            } else if let err = loadError, projects.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load projects", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(err)
                }
            } else if visibleProjects.isEmpty {
                // A damaged registry reads as an EMPTY one. Saying "no
                // projects yet" there is the single most misleading thing
                // this screen can say — the projects exist, we just
                // couldn't read them.
                ContentUnavailableView {
                    Label(
                        damage == nil ? "No projects yet" : "Projects couldn't be read",
                        systemImage: damage == nil ? "square.grid.2x2" : "exclamationmark.triangle.fill"
                    )
                } description: {
                    Text(damage ?? "Use the Mac app to add and configure projects — they'll appear here automatically.")
                }
            } else {
                projectList
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ProjectEntry.self) { project in
            ProjectDetailView(project: project, config: config)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private var projectList: some View {
        let folders = folderLabels
        List {
            if let damage {
                Section {
                    Label {
                        Text(damage)
                            .font(.footnote)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(ScarfColor.backgroundSecondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Projects registry damaged. \(damage)")
                }
            }
            // Top-level (no folder) projects first, then folder
            // disclosure sections — same shape as Mac
            // ProjectsSidebar.swift renders.
            let topLevel = visibleProjects.filter { ($0.folder ?? "").isEmpty }
            if !topLevel.isEmpty {
                Section {
                    ForEach(topLevel) { project in
                        projectRow(project)
                            .listRowBackground(ScarfColor.backgroundSecondary)
                    }
                }
            }
            ForEach(folders, id: \.self) { folder in
                Section(folder) {
                    ForEach(visibleProjects.filter { $0.folder == folder }) { project in
                        projectRow(project)
                            .listRowBackground(ScarfColor.backgroundSecondary)
                    }
                }
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
    }

    private func projectRow(_ project: ProjectEntry) -> some View {
        NavigationLink(value: project) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .scarfGoCompactListRow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), at \(project.path)")
        .accessibilityHint("Opens project dashboard, site, and sessions")
    }

    /// Visible projects = registry minus archived, sorted alphabetically.
    /// Mirrors Mac sidebar's default filter.
    private var visibleProjects: [ProjectEntry] {
        projects
            .filter { !$0.archived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Distinct, sorted folder labels across the visible set. Empty
    /// strings are treated as top-level (filtered out here so they
    /// don't render as a "" section title).
    private var folderLabels: [String] {
        let set = Set(visibleProjects.compactMap(\.folder).filter { !$0.isEmpty })
        return set.sorted()
    }

    /// Load the project registry over the active transport. Same
    /// pattern as `ProjectPickerSheet.loadProjects` — wrap the
    /// synchronous `ProjectDashboardService` calls in `Task.detached`
    /// so the SFTP read doesn't run on the MainActor.
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = serverContext
        // `loadRegistry()` is non-throwing (returns an empty registry on any
        // read failure), so the detached task can't throw — no do/catch.
        let loaded: (projects: [ProjectEntry], damage: String?) = await Task.detached {
            let service = ProjectDashboardService(context: ctx)
            let result = service.loadRegistryDetailed()
            return (result.registry.projects, Self.damageMessage(result))
        }.value
        projects = loaded.projects
        damage = loaded.damage
        loadError = nil

        // Announce only when damage NEWLY appears (nil -> non-nil, or a
        // different message) — not on every refresh, which would re-speak
        // the same sentence on each pull-to-refresh / auto-reload.
        if let damage, damage != lastAnnouncedDamage {
            AccessibilityNotification.Announcement(AttributedString(damage)).post()
        }
        lastAnnouncedDamage = damage
    }

    /// The user-facing sentence for a damaged read. `RegistryLoss.message`
    /// is the app-wide wording for the blocking kinds (dropped rows,
    /// quarantine, unreadable); field-level salvage isn't blocking but is
    /// still worth saying, so it gets its own line rather than silence.
    private static func damageMessage(
        _ result: ProjectDashboardService.RegistryLoadResult
    ) -> String? {
        if let loss = result.loss { return loss.message }
        guard result.salvaged else { return nil }
        let fields = result.salvage.salvagedFields
        guard !fields.isEmpty else { return nil }
        return "Some project details in \(result.registryPath) couldn't be read and were skipped: "
            + fields.joined(separator: ", ") + ". Fix them in the Mac app."
    }
}
