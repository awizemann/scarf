import SwiftUI

struct WhatsAppSetupView: View {
    @State private var viewModel = WhatsAppSetupViewModel()

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
            if let msg = viewModel.message {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("Reload") { viewModel.load() }.controlSize(.small)
            Button("Save") { viewModel.save() }.buttonStyle(.borderedProminent).controlSize(.small)
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            Text("A QR code will appear below. Scan it with WhatsApp on your phone. The session is saved to ~/.hermes/platforms/whatsapp/ so you won't need to scan again after restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            EmbeddedSetupTerminal(controller: viewModel.terminalController)
                .frame(minHeight: 260, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
