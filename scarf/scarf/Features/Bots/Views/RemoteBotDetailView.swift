import SwiftUI
import ScarfCore
import ScarfDesign

/// Detail pane for a row from the `bot_peers` registry — another Hermes
/// gateway this machine can message bot-to-bot (`hermes peer`, v0.21+).
///
/// Deliberately NOT the ACP conversation `BotConversationView` gives a local
/// bot: a peer is a whole other host, reached only through `hermes peer`'s
/// synchronous DM and asynchronous run verbs (W9's `HermesPeerCLI`), so this
/// is a simple compose/run pane, not a live transcript. Reuses W9's
/// `PeersViewModel` (`sendDM`/`startRun`/`refresh`/`stop`/`forget`)
/// unmodified — this view only narrows the picker away, since the peer is
/// already chosen by the roster row.
struct RemoteBotDetailView: View {
    @Bindable var viewModel: PeersViewModel
    let peer: HermesBotPeer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                header
                notice
                composer
                if !viewModel.runs.isEmpty {
                    runsList
                }
            }
            .padding(ScarfSpace.s4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(ScarfColor.backgroundPrimary)
        .onAppear { viewModel.selectedPeerName = peer.name }
    }

    private var header: some View {
        ScarfCard {
            HStack(alignment: .top, spacing: ScarfSpace.s3) {
                // Name-seeded generated fallback (B1) — a peer has no
                // profile.yaml to read a photo/color/shape from.
                BotAvatarView(displayName: peer.name, shapeString: nil, colorHex: nil, imageData: nil, size: 56)
                VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                    Text(peer.name)
                        .scarfStyle(.title3)
                    if !peer.note.isEmpty {
                        Text(peer.note)
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    Text(peer.url)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .textSelection(.enabled)
                    ScarfBadge("remote", kind: .info)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var notice: some View {
        Text("This is a peer on another host — messaging it goes over hermes peer, not a live conversation like a local bot's chat.")
            .scarfStyle(.caption)
            .foregroundStyle(ScarfColor.foregroundMuted)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader("Message")
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfTextField("Optional profile on \(peer.name) — leave blank for its default", text: $viewModel.profile)
                TextEditor(text: $viewModel.composeText)
                    .font(ScarfFont.mono)
                    .frame(minHeight: 90)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                            .fill(ScarfColor.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                                    .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
                            )
                    )
                    .scrollContentBackground(.hidden)
                HStack {
                    if viewModel.isSending { ProgressView().controlSize(.small) }
                    if let message = viewModel.message {
                        Text(message).scarfStyle(.caption).foregroundStyle(ScarfColor.success)
                    }
                    Spacer()
                    Button("Message") { viewModel.sendDM() }
                        .buttonStyle(ScarfGhostButton())
                        .disabled(viewModel.isSending || viewModel.composeText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Send a synchronous message to \(peer.name)")
                    Button("Run Async") { viewModel.startRun() }
                        .buttonStyle(ScarfPrimaryButton())
                        .disabled(viewModel.isSending || viewModel.composeText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Start an asynchronous run on \(peer.name)")
                }
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.danger)
                        .textSelection(.enabled)
                }
                if let durabilityNote = viewModel.durabilityNote {
                    Text(durabilityNote)
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.warning)
                }
                if let lastReply = viewModel.lastReply {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reply").scarfStyle(.caption).foregroundStyle(ScarfColor.foregroundMuted)
                        Text(lastReply).scarfStyle(.body).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var runsList: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            ScarfSectionHeader("Async runs")
            ScarfCard(padding: ScarfSpace.s3) {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    ForEach(viewModel.runs) { run in
                        HStack(alignment: .top, spacing: ScarfSpace.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.promptPreview).scarfStyle(.caption).lineLimit(1)
                                Text(run.status).scarfStyle(.footnote).foregroundStyle(ScarfColor.foregroundMuted)
                            }
                            Spacer(minLength: 0)
                            if !run.isTerminal {
                                Button("Refresh") { viewModel.refresh(run) }
                                    .buttonStyle(ScarfGhostButton())
                                Button("Stop") { viewModel.stop(run) }
                                    .buttonStyle(ScarfGhostButton())
                            }
                            Button("Forget") { viewModel.forget(run) }
                                .buttonStyle(ScarfGhostButton())
                        }
                    }
                }
            }
        }
    }
}
