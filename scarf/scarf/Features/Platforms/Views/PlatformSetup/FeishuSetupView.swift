import SwiftUI

struct FeishuSetupView: View {
    @State private var viewModel: FeishuSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: FeishuSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "App Credentials", icon: "key") {
                EditableTextField(label: "App ID", value: viewModel.appID) { viewModel.appID = $0 }
                SecretTextField(label: "App Secret", value: viewModel.appSecret) { viewModel.appSecret = $0 }
                PickerRow(label: "Domain", selection: viewModel.domain, options: viewModel.domainOptions) { viewModel.domain = $0 }
            }

            SettingsSection(title: "Webhook Security", icon: "lock.shield") {
                SecretTextField(label: "Encrypt Key", value: viewModel.encryptKey) { viewModel.encryptKey = $0 }
                SecretTextField(label: "Verification Token", value: viewModel.verificationToken) { viewModel.verificationToken = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                EditableTextField(label: "Allowed Users", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                PickerRow(label: "Connection Mode", selection: viewModel.connectionMode, options: viewModel.connectionOptions) { viewModel.connectionMode = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create an app in the Feishu/Lark Developer Console, enable Interactive Card if you need button responses, and copy the App ID and App Secret. WebSocket mode (recommended) doesn't need a public endpoint.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Feishu Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/feishu") }
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
