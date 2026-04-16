import SwiftUI

struct IMessageSetupView: View {
    @State private var viewModel = IMessageSetupViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "BlueBubbles Server", icon: "server.rack") {
                EditableTextField(label: "Server URL", value: viewModel.serverURL) { viewModel.serverURL = $0 }
                SecretTextField(label: "Server Password", value: viewModel.password) { viewModel.password = $0 }
            }

            SettingsSection(title: "Webhook (hermes side)", icon: "arrow.up.right.square") {
                EditableTextField(label: "Host", value: viewModel.webhookHost) { viewModel.webhookHost = $0 }
                EditableTextField(label: "Port", value: viewModel.webhookPort) { viewModel.webhookPort = $0 }
                EditableTextField(label: "Path", value: viewModel.webhookPath) { viewModel.webhookPath = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                ToggleRow(label: "Allow All Users", isOn: viewModel.allowAllUsers) { viewModel.allowAllUsers = $0 }
                if !viewModel.allowAllUsers {
                    EditableTextField(label: "Allowed Users", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                }
                EditableTextField(label: "Home Channel", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Send Read Receipts", isOn: viewModel.sendReadReceipts) { viewModel.sendReadReceipts = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iMessage integration runs through BlueBubbles Server. You need a Mac that stays on with Messages.app signed in — install BlueBubbles Server on it, then point hermes at that server's URL.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Install BlueBubbles Server") { PlatformSetupHelpers.openURL("https://bluebubbles.app/") }
                    .controlSize(.small)
                Button("BlueBubbles Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles") }
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
}
