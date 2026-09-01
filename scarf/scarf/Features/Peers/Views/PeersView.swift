import SwiftUI
import ScarfCore
import ScarfDesign

/// Peers — the minimal native surface for `hermes peer` (Hermes v0.21+).
///
/// Deliberately **not** a chat UI. It shows the `bot_peers:` registry,
/// gives one compose field with the two documented delivery verbs (a
/// synchronous DM that prints a reply, and an async run that returns a
/// handle), and tracks the handles with status/stop. A real bot-to-bot
/// conversation view is Bot Mode's job, not this one.
///
/// Visual grammar follows the other single-pane Configure/Manage routes
/// (Webhooks, Credential Pools): `ScarfPageHeader`, `ScarfCard` sections,
/// `ScarfSectionHeader` labels, plain-literal strings — the same
/// precedent those features set.
struct PeersView: View {
    // Coordinator-cached (t-aud24) so run handles survive section
    // switches — `hermes peer` has no way to re-enumerate them.
    @Bindable var viewModel: PeersViewModel

    init(viewModel: PeersViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    if let loadError = viewModel.loadError {
                        banner(loadError, icon: "exclamationmark.triangle.fill", tint: ScarfColor.warning)
                    }
                    if let errorMessage = viewModel.errorMessage {
                        banner(errorMessage, icon: "xmark.octagon.fill", tint: ScarfColor.danger)
                    }
                    if viewModel.isLoading && viewModel.peers.isEmpty {
                        // Don't flash "No peers registered" while a slow
                        // (remote) config read is still in flight.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ScarfSpace.s6)
                    } else if viewModel.peers.isEmpty {
                        emptyState
                    } else {
                        peersSection
                        composeSection
                        if !viewModel.runs.isEmpty { runsSection }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Peers")
        .onAppear { viewModel.load() }
    }

    // MARK: - Header

    private var header: some View {
        ScarfPageHeader(
            "Peers",
            subtitle: "Other Hermes gateways this machine can message bot-to-bot."
        ) {
            HStack(spacing: ScarfSpace.s2) {
                if let msg = viewModel.message {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.success)
                }
                Button("Reload") { viewModel.load(force: true) }
                    .buttonStyle(ScarfGhostButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Empty state

    /// Registration is a CLI-only flow on purpose: `hermes peer add`
    /// takes the peer's `API_SERVER_KEY`, and Scarf never handles keys.
    private var emptyState: some View {
        VStack(spacing: ScarfSpace.s3) {
            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text("No peers registered")
                .scarfStyle(.bodyEmph)
            Text("""
                 A peer is another machine running the Hermes api_server gateway. \
                 Register one from a terminal — the peer's API key is a credential, \
                 so Scarf leaves that step to the CLI:
                 """)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("hermes peer add spark --url http://spark.lan:8377 --key <API_SERVER_KEY>")
                .scarfStyle(.code)
                .textSelection(.enabled)
                .padding(ScarfSpace.s2)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary)
                )
            Text("Already added some? They live under bot_peers: in config.yaml — check with \(HermesPeerCLI.listCommandHint).")
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ScarfSpace.s6)
    }

    // MARK: - Registry

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader("Registered peers", subtitle: "From bot_peers: in config.yaml")
            ForEach(viewModel.peers) { peer in
                peerRow(peer)
            }
        }
    }

    private func peerRow(_ peer: HermesBotPeer) -> some View {
        let isSelected = viewModel.selectedPeerName == peer.name
        return Button {
            viewModel.selectedPeerName = peer.name
        } label: {
            ScarfCard(padding: ScarfSpace.s3) {
                HStack(alignment: .top, spacing: ScarfSpace.s3) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? ScarfColor.accent : ScarfColor.foregroundFaint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.name)
                            .scarfStyle(.bodyEmph)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                        Text(peer.url)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .textSelection(.enabled)
                        if !peer.note.isEmpty {
                            Text(peer.note)
                                .scarfStyle(.footnote)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                        }
                    }
                    Spacer(minLength: 0)
                    // The key itself is never read. Naming the variable
                    // is the useful, safe half of "is it configured?".
                    Text(peer.keyEnvName)
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .help("The peer's API key is read from ~/.hermes/.env under this name. Scarf never reads or displays its value.")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(peer.name), \(peer.url), \(peer.note), key \(peer.keyEnvName), \(isSelected ? "selected" : "not selected")")
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Compose

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader(
                "Send",
                subtitle: "Delivered into the remote agent's canonical Bot Chat session."
            )
            ScarfCard {
                VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                    HStack(spacing: ScarfSpace.s2) {
                        Text(viewModel.selectedPeer?.name ?? "—")
                            .scarfStyle(.bodyEmph)
                        Text("/")
                            .foregroundStyle(ScarfColor.foregroundFaint)
                        ScarfTextField("agent (optional)", text: $viewModel.profile)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("agent (optional)")
                            .help("Named profile on a multiplexed peer — targets <peer>/<agent>. Leave empty for the peer's own launch profile.")
                    }
                    TextEditor(text: $viewModel.composeText)
                        .scarfStyle(.body)
                        .frame(minHeight: 84)
                        .padding(ScarfSpace.s2)
                        .background(
                            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                                .fill(ScarfColor.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                                .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                        )
                        .accessibilityLabel("Send")
                    HStack(spacing: ScarfSpace.s2) {
                        if viewModel.isSending { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Start Run") { viewModel.startRun() }
                            .buttonStyle(ScarfSecondaryButton())
                            .disabled(!canSend)
                            .help("Start the same turn asynchronously and track it by run ID. Use this for long turns.")
                        Button("Send DM") { viewModel.sendDM() }
                            .buttonStyle(ScarfPrimaryButton())
                            .disabled(!canSend)
                            .help("Run one synchronous turn on the peer and show its reply. Can take minutes.")
                    }
                    if let note = viewModel.durabilityNote {
                        Label(note, systemImage: "info.circle")
                            .scarfStyle(.footnote)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    if let reply = viewModel.lastReply {
                        ScarfDivider()
                        Text("Reply")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Text(reply)
                            .scarfStyle(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var canSend: Bool {
        viewModel.selectedPeer != nil
            && !viewModel.isSending
            && !viewModel.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Runs

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader(
                "Runs",
                subtitle: "Tracked while this window stays open — Hermes can't re-list peer runs."
            )
            ForEach(viewModel.runs) { run in
                runRow(run)
            }
        }
    }

    private func runRow(_ run: PeerRunRow) -> some View {
        ScarfCard(padding: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                HStack(spacing: ScarfSpace.s2) {
                    Text(run.id)
                        .scarfStyle(.code)
                        .textSelection(.enabled)
                    ScarfBadge(verbatim: run.status, kind: badgeKind(for: run))
                    if run.replayed { ScarfBadge("replayed", kind: .info) }
                    Spacer(minLength: 0)
                    if run.isBusy { ProgressView().controlSize(.small) }
                    Button("Refresh") { viewModel.refresh(run) }
                        .buttonStyle(ScarfGhostButton())
                        .disabled(run.isBusy)
                        .accessibilityLabel("Refresh run \(run.id) on \(run.target)")
                    if !run.isTerminal {
                        Button("Stop") { viewModel.stop(run) }
                            .buttonStyle(ScarfGhostButton())
                            .disabled(run.isBusy)
                            .accessibilityLabel("Stop run \(run.id) on \(run.target)")
                    }
                    Button("Dismiss") { viewModel.forget(run) }
                        .buttonStyle(ScarfGhostButton())
                        .accessibilityLabel("Dismiss run \(run.id) on \(run.target)")
                }
                Text("\(run.target) · \(run.promptPreview)")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(1)
                if let output = run.output {
                    Text(output)
                        .scarfStyle(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = run.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.danger)
                }
            }
        }
    }

    private func badgeKind(for run: PeerRunRow) -> ScarfBadgeKind {
        switch run.status.lowercased() {
        case "completed", "succeeded": return .success
        case "failed", "error", "cancelled", "canceled", "stopped": return .danger
        case "unknown": return .neutral
        default: return .brand
        }
    }

    // MARK: - Banners

    private func banner(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: icon).foregroundStyle(tint)
            // Verbatim CLI text: the actionable failures here (peer's
            // hermes-agent too old, missing HERMES_PEER_<NAME>_KEY) carry
            // their own remedy, and paraphrasing would lose it.
            Text(text)
                .scarfStyle(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}
