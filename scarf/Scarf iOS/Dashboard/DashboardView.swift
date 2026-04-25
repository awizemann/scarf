import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

/// iOS Dashboard — adopts the Mac-style card layout (status row +
/// stats grid + recent-sessions card) instead of a native iOS list.
/// Sessions sub-tab keeps a List view for scrolling density but
/// renders against the rust page background.
struct DashboardView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle
    /// Soft-disconnect closure threaded down from the connected-server
    /// host. Surfaced in the nav bar as a "Switch server" button so
    /// users can hop back to the server list without first navigating
    /// to the System tab.
    let onSoftDisconnect: (@MainActor () async -> Void)?

    @Environment(\.scarfGoCoordinator) private var coordinator
    @State private var vm: IOSDashboardViewModel
    @State private var selectedSection: Section = .overview
    @State private var sessionProjectFilter: String? = nil
    @State private var isDisconnecting = false

    enum Section: Hashable { case overview, sessions }

    private static let contextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    init(
        config: IOSServerConfig,
        key: SSHKeyBundle,
        onSoftDisconnect: (@MainActor () async -> Void)? = nil
    ) {
        self.config = config
        self.key = key
        self.onSoftDisconnect = onSoftDisconnect
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
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.top, ScarfSpace.s2)
            .padding(.bottom, ScarfSpace.s1)

            Group {
                switch selectedSection {
                case .overview: overviewContent
                case .sessions: sessionsList
                }
            }
        }
        .background(ScarfColor.backgroundPrimary.ignoresSafeArea())
        .navigationTitle(config.displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let onSoftDisconnect {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isDisconnecting = true
                            await onSoftDisconnect()
                        }
                    } label: {
                        if isDisconnecting {
                            ProgressView()
                        } else {
                            Label("Switch server", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    .disabled(isDisconnecting)
                    .accessibilityLabel("Switch server")
                    .accessibilityHint("Disconnects from this server and returns to the server list")
                }
            }
        }
        .refreshable { await vm.refresh() }
        .overlay {
            if vm.isLoading, vm.recentSessions.isEmpty {
                ProgressView("Loading dashboard…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
            }
        }
        .task { await vm.load() }
    }

    // MARK: - Overview (Mac-style cards)

    @ViewBuilder
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                if let err = vm.lastError {
                    errorBanner(err)
                }

                statsSection

                if !vm.recentSessions.isEmpty {
                    recentSessionsSection
                }
            }
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, ScarfSpace.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(ScarfColor.backgroundPrimary)
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection issue")
                    .font(.headline)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(err)
                    .font(.callout)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task { await vm.refresh() }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.warning.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                        .strokeBorder(ScarfColor.warning.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text("Activity")
                .font(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: ScarfSpace.s3),
                          GridItem(.flexible(), spacing: ScarfSpace.s3)],
                spacing: ScarfSpace.s3
            ) {
                statCard(label: "Sessions", value: "\(vm.stats.totalSessions)")
                statCard(label: "Messages", value: "\(vm.stats.totalMessages)")
                statCard(label: "Tool Calls", value: "\(vm.stats.totalToolCalls)")
                statCard(
                    label: "Tokens",
                    value: formatTokens(vm.stats.totalInputTokens + vm.stats.totalOutputTokens),
                    sub: tokenSub
                )
            }
        }
    }

    private var tokenSub: String? {
        let inT = vm.stats.totalInputTokens
        let outT = vm.stats.totalOutputTokens
        guard inT + outT > 0 else { return nil }
        return "\(formatTokens(inT)) in · \(formatTokens(outT)) out"
    }

    private func statCard(label: String, value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text("Recent sessions")
                    .font(.headline)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer()
                Button("See all") { selectedSection = .sessions }
                    .font(.caption)
                    .foregroundStyle(ScarfColor.accent)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(Array(vm.recentSessions.enumerated()), id: \.element.id) { idx, session in
                    sessionRow(session)
                        .padding(.horizontal, ScarfSpace.s3)
                        .padding(.vertical, ScarfSpace.s2 + 2)
                    if idx < vm.recentSessions.count - 1 {
                        Rectangle()
                            .fill(ScarfColor.border)
                            .frame(height: 1)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .strokeBorder(ScarfColor.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Sessions sub-tab

    @ViewBuilder
    private var sessionsList: some View {
        VStack(spacing: 0) {
            if !vm.allProjects.isEmpty {
                filterBar
                    .padding(.horizontal, ScarfSpace.s3)
                    .padding(.vertical, ScarfSpace.s2)
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
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filtered) { session in
                        sessionRow(session)
                            .listRowBackground(ScarfColor.backgroundSecondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ScarfColor.backgroundPrimary)
        }
    }

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
                .foregroundStyle(ScarfColor.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ScarfColor.accentTint, in: Capsule())
            }
            Spacer()
        }
    }

    // MARK: - Row helper

    @ViewBuilder
    private func sessionRow(_ session: HermesSession) -> some View {
        Button {
            coordinator?.resumeSession(session.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                HStack(spacing: 12) {
                    Label(session.source, systemImage: session.sourceIcon)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    if let started = session.startedAt {
                        Text(started, format: .relative(presentation: .numeric))
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    if session.apiCallCount > 0 {
                        Label("\(session.apiCallCount)", systemImage: "network")
                            .font(.caption2)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
                if let projectName = vm.projectName(for: session) {
                    Label(projectName, systemImage: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(ScarfColor.accent)
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(ScarfColor.accentTint, in: Capsule())
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
