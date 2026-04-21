import SwiftUI

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var showDiagnostics = false
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: DashboardViewModel(context: context))
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let err = viewModel.lastReadError {
                    readErrorBanner(err)
                }
                statusSection
                statsSection
                recentSessionsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading dashboard…",
            isEmpty: viewModel.recentSessions.isEmpty
        )
        .task { await viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
        .sheet(isPresented: $showDiagnostics) {
            RemoteDiagnosticsView(context: viewModel.context)
        }
    }

    /// Banner shown above the Dashboard when one or more remote reads
    /// failed (permission denied, missing sqlite3, wrong home dir, etc.).
    /// Replaces the old silent-failure mode where empty values just
    /// appeared as "Stopped / unknown / 0" with no explanation.
    private func readErrorBanner(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can't read Hermes state on \(viewModel.context.displayName)")
                        .font(.headline)
                    Text(err)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Run Diagnostics…", systemImage: "stethoscope")
                }
                .controlSize(.regular)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusSection: some View {
        HStack(spacing: 16) {
            StatusCard(
                title: "Hermes",
                value: viewModel.hermesRunning ? "Running" : "Stopped",
                icon: "circle.fill",
                color: viewModel.hermesRunning ? .green : .secondary
            )
            StatusCard(
                title: "Model",
                value: viewModel.config.model,
                icon: "cpu",
                color: .blue
            )
            StatusCard(
                title: "Provider",
                value: viewModel.config.provider,
                icon: "cloud",
                color: .purple
            )
            StatusCard(
                title: "Gateway",
                value: viewModel.gatewayState?.statusText ?? "unknown",
                icon: "network",
                color: viewModel.gatewayState?.isRunning == true ? .green : .secondary
            )
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage Stats")
                .font(.headline)
            HStack(spacing: 16) {
                StatCard(label: "Sessions", value: "\(viewModel.stats.totalSessions)")
                StatCard(label: "Messages", value: "\(viewModel.stats.totalMessages)")
                StatCard(label: "Tool Calls", value: "\(viewModel.stats.totalToolCalls)")
                StatCard(label: "Tokens", value: formatTokens(viewModel.stats.totalInputTokens + viewModel.stats.totalOutputTokens))
                let cost = viewModel.stats.totalActualCostUSD > 0 ? viewModel.stats.totalActualCostUSD : viewModel.stats.totalCostUSD
                if cost > 0 {
                    StatCard(label: "Cost", value: cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                }
            }
        }
    }

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Sessions")
                    .font(.headline)
                Spacer()
                Button("View All") {
                    coordinator.selectedSection = .sessions
                }
                .buttonStyle(.link)
            }
            ForEach(viewModel.recentSessions) { session in
                SessionRow(session: session, preview: viewModel.sessionPreviews[session.id])
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.selectedSessionId = session.id
                        coordinator.selectedSection = .sessions
                    }
            }
            if viewModel.recentSessions.isEmpty && !viewModel.isLoading {
                Text("No sessions found")
                    .foregroundStyle(.secondary)
            }
        }
    }

}

struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SessionRow: View {
    let session: HermesSession
    var preview: String?

    var body: some View {
        HStack {
            Image(systemName: session.sourceIcon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview ?? session.displayTitle)
                    .lineLimit(1)
                if let date = session.startedAt {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                Label("\(session.messageCount)", systemImage: "bubble.left")
                Label("\(session.toolCallCount)", systemImage: "wrench")
                if let cost = session.displayCostUSD, cost > 0 {
                    Label(cost.formatted(.currency(code: "USD").precision(.fractionLength(4))), systemImage: "dollarsign.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
