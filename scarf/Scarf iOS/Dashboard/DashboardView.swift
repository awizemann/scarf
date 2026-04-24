import SwiftUI
import ScarfCore
import ScarfIOS

/// iOS Dashboard — shows session count, token usage, cost, and the
/// last 5 sessions pulled from the remote Hermes SQLite snapshot.
/// Every data source routes through `ServerContext → CitadelServerTransport`
/// so the same services that drive the Mac Dashboard power this one.
struct DashboardView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle

    @Environment(\.scarfGoCoordinator) private var coordinator
    @State private var vm: IOSDashboardViewModel
    @State private var selectedSection: Section = .overview
    @State private var sessionProjectFilter: String? = nil

    /// Two top-level surfaces in the Dashboard. Overview = stats +
    /// 5 most-recent sessions for glance. Sessions = the 25-session
    /// deeper list with a project filter. Split added in pass-2 per
    /// user feedback — the old single-List layout grew too busy
    /// once we started adding project badges, and users wanted a
    /// way to slice by project.
    enum Section: Hashable { case overview, sessions }

    /// Stable ID used when building the `ServerContext` — tied to the
    /// config's host+user tuple so re-launching the app without reset
    /// yields the same ID (important for the snapshot cache dir).
    private static let contextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    init(
        config: IOSServerConfig,
        key: SSHKeyBundle
    ) {
        self.config = config
        self.key = key
        let ctx = config.toServerContext(id: Self.contextID)
        _vm = State(initialValue: IOSDashboardViewModel(context: ctx))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedSection) {
                Text("Overview").tag(Section.overview)
                Text("Sessions").tag(Section.sessions)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Group {
                switch selectedSection {
                case .overview: overviewList
                case .sessions: sessionsList
                }
            }
        }
        .scarfGoListDensity()
        .navigationTitle(config.displayName)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await vm.refresh() }
        .overlay {
            if vm.isLoading, vm.recentSessions.isEmpty {
                ProgressView("Loading dashboard…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .task { await vm.load() }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewList: some View {
        List {
            if let err = vm.lastError {
                SwiftUI.Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Connection issue", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await vm.refresh() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }

            SwiftUI.Section("Activity") {
                statRow("Total sessions", value: "\(vm.stats.totalSessions)")
                statRow("Total messages", value: "\(vm.stats.totalMessages)")
                statRow("Tool calls", value: "\(vm.stats.totalToolCalls)")
            }

            SwiftUI.Section("Tokens") {
                statRow("Input", value: formatTokens(vm.stats.totalInputTokens))
                statRow("Output", value: formatTokens(vm.stats.totalOutputTokens))
                statRow("Reasoning", value: formatTokens(vm.stats.totalReasoningTokens))
            }

            if !vm.recentSessions.isEmpty {
                SwiftUI.Section {
                    ForEach(vm.recentSessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    HStack {
                        Text("Recent sessions")
                        Spacer()
                        Button("See all") { selectedSection = .sessions }
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }
        }
    }

    // MARK: - Sessions sub-tab

    @ViewBuilder
    private var sessionsList: some View {
        VStack(spacing: 0) {
            if !vm.allProjects.isEmpty {
                filterBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            List {
                let filtered = vm.sessions(filteredBy: sessionProjectFilter)
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No sessions",
                        systemImage: "clock.badge.questionmark",
                        description: Text(sessionProjectFilter == nil
                            ? "No sessions to show yet — start a chat from the Chat tab."
                            : "No sessions for that project yet. Try another filter or start a chat in that project.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    /// Project filter control rendered above the Sessions list. Uses
    /// a Menu instead of a segmented Picker because there can be many
    /// projects — segments don't scale past 3–4 options on a phone.
    /// Shows the active filter as the button label (tappable to
    /// change); an explicit "All projects" entry clears the filter.
    @ViewBuilder
    private var filterBar: some View {
        HStack {
            Menu {
                Button {
                    sessionProjectFilter = nil
                } label: {
                    Label("All projects", systemImage: "tray.full")
                }
                Divider()
                ForEach(vm.allProjects.sorted { $0.name < $1.name }) { project in
                    Button {
                        sessionProjectFilter = project.name
                    } label: {
                        Label(project.name, systemImage: "folder.fill")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sessionProjectFilter == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                    Text(sessionProjectFilter ?? "All projects")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.1), in: Capsule())
            }
            Spacer()
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func sessionRow(_ session: HermesSession) -> some View {
        Button {
            coordinator?.resumeSession(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 12) {
                    Label(session.source, systemImage: session.sourceIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let started = session.startedAt {
                        Text(started, format: .relative(presentation: .numeric))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let projectName = vm.projectName(for: session) {
                    Label(projectName, systemImage: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Mirror of `ScarfCore.formatTokens` — inlined here rather than
    /// exported from ScarfCore because it's currently wrapped in
    /// `#if canImport(SQLite3)` (from the M0d InsightsViewModel move).
    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
