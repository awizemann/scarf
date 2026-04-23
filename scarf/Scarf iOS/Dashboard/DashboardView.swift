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
    let onDisconnect: @MainActor () async -> Void

    @State private var vm: IOSDashboardViewModel
    @State private var isDisconnecting = false

    /// Stable ID used when building the `ServerContext` — tied to the
    /// config's host+user tuple so re-launching the app without reset
    /// yields the same ID (important for the snapshot cache dir).
    private static let contextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    init(
        config: IOSServerConfig,
        key: SSHKeyBundle,
        onDisconnect: @escaping @MainActor () async -> Void
    ) {
        self.config = config
        self.key = key
        self.onDisconnect = onDisconnect
        let ctx = config.toServerContext(id: Self.contextID)
        _vm = State(initialValue: IOSDashboardViewModel(context: ctx))
    }

    var body: some View {
        NavigationStack {
            List {
                if let err = vm.lastError {
                    Section {
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

                Section("Activity") {
                    statRow("Total sessions", value: "\(vm.stats.totalSessions)")
                    statRow("Total messages", value: "\(vm.stats.totalMessages)")
                    statRow("Tool calls", value: "\(vm.stats.totalToolCalls)")
                }

                Section("Tokens") {
                    statRow("Input", value: formatTokens(vm.stats.totalInputTokens))
                    statRow("Output", value: formatTokens(vm.stats.totalOutputTokens))
                    statRow("Reasoning", value: formatTokens(vm.stats.totalReasoningTokens))
                }

                if !vm.recentSessions.isEmpty {
                    Section("Recent sessions") {
                        ForEach(vm.recentSessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayTitle)
                                    .font(.body)
                                    .lineLimit(2)
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
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Surfaces") {
                    NavigationLink {
                        ChatView(config: config, key: key)
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    NavigationLink {
                        MemoryListView(config: config)
                    } label: {
                        Label("Memory", systemImage: "brain.head.profile")
                    }
                    NavigationLink {
                        CronListView(config: config)
                    } label: {
                        Label("Cron", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        SkillsListView(config: config)
                    } label: {
                        Label("Skills", systemImage: "sparkles")
                    }
                    NavigationLink {
                        SettingsView(config: config)
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }

                Section("Connected to") {
                    LabeledContent("Host", value: config.host)
                    if let user = config.user {
                        LabeledContent("User", value: user)
                    }
                    if let port = config.port {
                        LabeledContent("Port", value: String(port))
                    }
                    LabeledContent("Device key", value: key.displayFingerprint)
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            isDisconnecting = true
                            await onDisconnect()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isDisconnecting {
                                ProgressView()
                            } else {
                                Text("Disconnect")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDisconnecting)
                }
            }
            .navigationTitle(config.displayName)
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await vm.refresh()
            }
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
