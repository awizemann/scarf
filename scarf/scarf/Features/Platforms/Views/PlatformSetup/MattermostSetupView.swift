import SwiftUI

struct MattermostSetupView: View {
    @State private var viewModel: MattermostSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: MattermostSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Server", icon: "network") {
                EditableTextField(label: "Server URL", value: viewModel.serverURL) { viewModel.serverURL = $0 }
                SecretTextField(label: "Token", value: viewModel.token) { viewModel.token = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                EditableTextField(label: "Allowed Users", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                EditableTextField(label: "Home Channel", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
                EditableTextField(label: "Free-Response Channels", value: viewModel.freeResponseChannels) { viewModel.freeResponseChannels = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Require @mention", isOn: viewModel.requireMention) { viewModel.requireMention = $0 }
                PickerRow(label: "Reply Mode", selection: viewModel.replyMode, options: viewModel.replyModeOptions) { viewModel.replyMode = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create a personal access token under Profile → Security → Personal Access Tokens, or create a bot account. Use the token as the MATTERMOST_TOKEN value.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Mattermost Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/mattermost") }
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
