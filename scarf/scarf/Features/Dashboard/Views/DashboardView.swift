import SwiftUI

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusSection
                statsSection
                recentSessionsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
        .task { await viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
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

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
