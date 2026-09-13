import SwiftUI
import ScarfCore
import ScarfDesign

struct WhatsAppSetupView: View {
    @State private var viewModel: WhatsAppSetupViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: WhatsAppSetupViewModel(context: context))
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Status", icon: "power") {
                ToggleRow(label: "WhatsApp Enabled", isOn: viewModel.enabled) { viewModel.enabled = $0 }
                PickerRow(label: "Mode", selection: viewModel.mode, options: viewModel.modeOptions) { viewModel.mode = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                ToggleRow(label: "Allow All Users", isOn: viewModel.allowAllUsers) { viewModel.allowAllUsers = $0 }
                if !viewModel.allowAllUsers {
                    EditableTextField(label: "Allowed Numbers", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                PickerRow(label: "Unauthorized DM", selection: viewModel.unauthorizedDMBehavior, options: viewModel.unauthorizedOptions) { viewModel.unauthorizedDMBehavior = $0 }
                EditableTextField(label: "Reply Prefix", value: viewModel.replyPrefix) { viewModel.replyPrefix = $0 }
            }

            saveBar

            // v0.13 Messaging Gateway behavior — self-hides on pre-v0.13.
            GatewayBehaviorSection(
                platform: "whatsapp",
                capabilities: capabilitiesStore?.capabilities ?? .empty,
                context: context
            )

            Divider()
            pairingSection
        }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.stopPairing() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WhatsApp uses the Baileys library to emulate a WhatsApp Web session. Pair this Mac as a linked device by running the pairing wizard and scanning the QR code with your phone (Settings → Linked Devices → Link a Device).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("WhatsApp Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp") }
                    .controlSize(.small)
            }
        }
    }

    private var saveBar: some View {
        HStack {
            OutcomeMessageBar(
                text: viewModel.message,
                kind: viewModel.messageKind,
                onDismiss: { viewModel.dismissMessage() }
            )
            Spacer()
            Button("Reload") { viewModel.load() }.controlSize(.small)
                    .disabled(viewModel.isBusy)
            Button("Save") { viewModel.save() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
                // Disabled until the (now off-main, C10) load has landed:
                // `saveForm` treats a blank field as an unset, so a Save from
                // the pre-load blanks would comment live keys out of `.env`.
                .disabled(viewModel.isBusy)
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Pair Device", systemImage: "qrcode")
                    .font(.headline)
                Spacer()
                if viewModel.pairingInProgress {
                    Button("Stop") { viewModel.stopPairing() }
                        .controlSize(.small)
                } else {
                    Button("Start Pairing") { viewModel.startPairing() }
                        .buttonStyle(ScarfPrimaryButton())
                        .controlSize(.small)
                        // Round-5 decision 15: the embedded terminal spawns
                        // on THIS Mac, and `hermesBinary` is the remote path.
                        .disabled(viewModel.remotePairingNotice != nil)
                }
            }
            // On a remote context the terminal below can only mislead, so the
            // sentence naming the host REPLACES the how-to rather than
            // sitting beside it.
            if let notice = viewModel.remotePairingNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("A QR code will appear below. Scan it with WhatsApp on your phone. The session is saved to ~/.hermes/platforms/whatsapp/ so you won't need to scan again after restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EmbeddedSetupTerminal(controller: viewModel.terminalController)
                    .frame(minHeight: 260, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
