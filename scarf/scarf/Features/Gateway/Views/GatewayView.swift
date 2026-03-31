import SwiftUI

struct GatewayView: View {
    @State private var viewModel = GatewayViewModel()
    @Environment(HermesFileWatcher.self) private var fileWatcher

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                serviceSection
                platformsSection
                pairingSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Gateway")
        .onAppear { viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) { viewModel.load() }
    }

    // MARK: - Service

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Service")
                    .font(.headline)
                Spacer()
                if let msg = viewModel.actionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Start") { viewModel.startGateway() }
                    Button("Stop") { viewModel.stopGateway() }
                    Button("Restart") { viewModel.restartGateway() }
                }
                .controlSize(.small)
            }

            HStack(spacing: 16) {
                StatusBadge(
                    label: viewModel.gateway.state,
                    isActive: viewModel.gateway.state == "running"
                )
                if let pid = viewModel.gateway.pid {
                    Label("PID \(pid)", systemImage: "number")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if viewModel.gateway.isLoaded {
                    Label("Loaded", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if viewModel.gateway.isStale {
                    Label("Service definition stale", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let reason = viewModel.gateway.exitReason, !reason.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let updated = viewModel.gateway.updatedAt {
                Text("Last updated: \(updated)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Platforms

    private var platformsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Platforms")
                .font(.headline)
            if viewModel.gateway.platforms.isEmpty {
                Text("No platforms connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(viewModel.gateway.platforms) { platform in
                        VStack(spacing: 6) {
                            Image(systemName: platform.icon)
                                .font(.title2)
                                .foregroundStyle(platform.isConnected ? Color.accentColor : .secondary)
                            Text(platform.name.capitalized)
                                .font(.caption.bold())
                            StatusBadge(
                                label: platform.state,
                                isActive: platform.isConnected
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paired Users")
                .font(.headline)

            if !viewModel.pendingPairings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Pending Approvals", systemImage: "clock.badge.questionmark")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    ForEach(viewModel.pendingPairings) { pending in
                        HStack {
                            Label(pending.platform.capitalized, systemImage: platformIcon(pending.platform))
                            Text("Code: \(pending.code)")
                                .font(.caption.monospaced())
                            Spacer()
                            Button("Approve") {
                                viewModel.approvePairing(platform: pending.platform, code: pending.code)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                        .font(.caption)
                        .padding(8)
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if viewModel.approvedUsers.isEmpty && viewModel.pendingPairings.isEmpty {
                Text("No paired users")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.approvedUsers) { user in
                    HStack {
                        Image(systemName: platformIcon(user.platform))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name)
                            Text("\(user.platform.capitalized) · \(user.userId)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) {
                            viewModel.revokeUser(user)
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "telegram": return "paperplane"
        case "discord": return "bubble.left.and.bubble.right"
        case "slack": return "number"
        case "whatsapp": return "phone.bubble"
        case "signal": return "lock.shield"
        case "email": return "envelope"
        default: return "bubble.left"
        }
    }
}

struct StatusBadge: View {
    let label: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? .green : .secondary)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
        }
    }
}
