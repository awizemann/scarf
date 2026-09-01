import SwiftUI
import ScarfCore
import ScarfDesign

/// Messaging Gateway page. Routes outbound chat to Discord / Telegram /
/// Slack / etc. — distinct from the v0.10 **Tool Gateway** (Nous Portal
/// subscription routing for web search / image / TTS / browser), which
/// lives under `Features/Health/`. The user-facing label here is always
/// "Messaging Gateway"; the SwiftUI struct stays `GatewayView` because
/// `ContentView` references it by name (rename-on-touch invariant —
/// avoid churning unrelated callers).
struct GatewayView: View {
    @State private var viewModel: MessagingGatewayViewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(context: ServerContext) {
        // Capabilities arrive via environment after init runs, so the VM
        // is constructed with `.empty` and refreshed on first appear via
        // `attach(capabilities:)`. Same pattern as the per-platform setup
        // views — see `MessagingGatewayViewModel.capabilities` doc comment.
        _viewModel = State(initialValue: MessagingGatewayViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Messaging Gateway",
                subtitle: "Outbound channel bridge — Discord, Telegram, Slack, Google Chat, etc."
            )
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    if let snap = viewModel.gatewayList,
                       viewModel.capabilities.hasGatewayList,
                       !snap.profiles.isEmpty {
                        crossProfileDigest(snap)
                    }
                    serviceSection
                    platformsSection
                    pairingSection
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Messaging Gateway")
        .onAppear {
            attachCapabilitiesIfNeeded()
            viewModel.load()
        }
        .onChange(of: fileWatcher.lastChangeDate) { viewModel.load() }
    }

    /// Re-create the VM with the resolved capabilities the first time the
    /// store hands us non-empty data. Same shape as `KanbanBoardView`'s
    /// `attach` helper.
    private func attachCapabilitiesIfNeeded() {
        guard let store = capabilitiesStore,
              store.capabilities.detected,
              !viewModel.capabilities.detected else { return }
        viewModel = MessagingGatewayViewModel(
            context: viewModel.context,
            capabilities: store.capabilities
        )
    }

    // MARK: - v0.13 cross-profile digest

    /// One-line summary above the gateway controls when the host is on
    /// v0.13+ and `hermes gateway list --json` returned at least one
    /// profile. Doubly-guarded — `hasGatewayList` AND `profiles != []`
    /// — so a v0.13 host with no registered profiles doesn't render
    /// an empty pill.
    private func crossProfileDigest(_ snap: GatewayListSnapshot) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(ScarfColor.accent)
            Text(snap.headerDigest)
                .scarfStyle(.captionStrong)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    // MARK: - Service

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            HStack {
                Text("Service")
                    .font(.headline)
                Spacer()
                if let msg = viewModel.actionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: ScarfSpace.s2) {
                    Button("Start") { viewModel.startGateway() }
                        .buttonStyle(ScarfPrimaryButton())
                        .controlSize(.small)
                    Button("Stop") { viewModel.stopGateway() }
                        .buttonStyle(ScarfSecondaryButton())
                        .controlSize(.small)
                    Button("Restart") { viewModel.restartGateway() }
                        .buttonStyle(ScarfSecondaryButton())
                        .controlSize(.small)
                }
            }

            HStack(spacing: ScarfSpace.s3) {
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
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text("Platforms")
                .font(.headline)
            if viewModel.gateway.platforms.isEmpty {
                Text("No platforms connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: ScarfSpace.s3) {
                    ForEach(viewModel.gateway.platforms) { platform in
                        VStack(spacing: 6) {
                            Image(systemName: platform.icon)
                                .font(.title2)
                                .foregroundStyle(platform.isConnected ? Color.accentColor : .secondary)
                            Text(verbatim: platform.name.capitalized)
                                .font(.caption.bold())
                            StatusBadge(
                                label: platform.state,
                                isActive: platform.isConnected
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(ScarfSpace.s3)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
                    }
                }
            }
        }
    }

    // MARK: - Pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Paired Users")
                .font(.headline)

            if !viewModel.pendingPairings.isEmpty {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
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
                            .buttonStyle(ScarfPrimaryButton())
                        }
                        .font(.caption)
                        .padding(ScarfSpace.s2)
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
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
                    .padding(ScarfSpace.s2)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
                }
            }
        }
    }

    private func platformIcon(_ platform: String) -> String {
        KnownPlatforms.icon(for: platform)
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
