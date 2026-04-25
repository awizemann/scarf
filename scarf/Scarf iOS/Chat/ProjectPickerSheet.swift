import SwiftUI
import ScarfCore
import ScarfDesign

/// Sheet presented from ChatView's "+" toolbar button. Offers two
/// modes:
/// - **Quick chat** — starts with `cwd = $HOME`, no project attribution.
///   The current default behavior.
/// - **In project…** — lets the user pick a registered project. On
///   confirm, the caller is handed back the project path so it can
///   (1) write the Scarf-managed AGENTS.md block via
///   `ProjectContextBlock.writeBlock` and (2) spawn `hermes acp` with
///   `cwd = project.path`, then attribute the resulting session.
///
/// The project list is loaded from the remote Hermes's
/// `~/.hermes/scarf/projects.json` via the shared
/// `ProjectDashboardService` (transport-backed, so SFTP works).
struct ProjectPickerSheet: View {
    let context: ServerContext
    let onQuickChat: () -> Void
    let onProject: (ProjectEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var projects: [ProjectEntry] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onQuickChat()
                        dismiss()
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quick chat")
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                Text("No project — agent runs in your home directory.")
                                    .font(.caption)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .scarfGoCompactListRow()
                }

                Section("In project…") {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.vertical, 8)
                    } else if let err = loadError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else if projects.isEmpty {
                        Text("No Scarf projects registered yet. Create one in the Mac app's Projects sidebar.")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    } else {
                        ForEach(sortedVisibleProjects) { project in
                            Button {
                                onProject(project)
                                dismiss()
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28)
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
                            .buttonStyle(.plain)
                            .scarfGoCompactListRow()
                        }
                    }
                }
            }
            .scarfGoListDensity()
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadProjects() }
        }
        .presentationDetents([.height(320), .large])
        .presentationDragIndicator(.visible)
    }

    /// Hide archived projects from the picker (they're deliberately
    /// out-of-sight on the Mac sidebar; honor that on iOS too).
    /// Sort alphabetically for predictability.
    private var sortedVisibleProjects: [ProjectEntry] {
        projects
            .filter { !$0.archived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Load the project registry over SFTP via the shared
    /// `ProjectDashboardService`. Transport-backed, so on iOS this
    /// reads `~/.hermes/scarf/projects.json` through the open Citadel
    /// connection. A missing/empty registry isn't an error — just
    /// means no projects are configured yet.
    private func loadProjects() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = context
        let loaded: [ProjectEntry] = await Task.detached {
            let service = ProjectDashboardService(context: ctx)
            return service.loadRegistry().projects
        }.value
        projects = loaded
    }
}
