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
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("Use the Mac app to add and configure projects — they'll appear here automatically.")
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
            // Top-level (no folder) projects first, then folder
            // disclosure sections — same shape as Mac
            // ProjectsSidebar.swift renders.
            let topLevel = visibleProjects.filter { ($0.folder ?? "").isEmpty }
            if !topLevel.isEmpty {
                Section {
                    ForEach(topLevel) { project in
                        projectRow(project)
                    }
                }
            }
            ForEach(folders, id: \.self) { folder in
                Section(folder) {
                    ForEach(visibleProjects.filter { $0.folder == folder }) { project in
                        projectRow(project)
                    }
                }
            }
        }
        .scarfGoListDensity()
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
        do {
            let loaded: [ProjectEntry] = try await Task.detached {
                let service = ProjectDashboardService(context: ctx)
                return service.loadRegistry().projects
            }.value
            projects = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
