import SwiftUI

struct SlackSetupView: View {
    @State private var viewModel = SlackSetupViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Required Tokens", icon: "key") {
                SecretTextField(label: "Bot Token (xoxb-)", value: viewModel.botToken) { viewModel.botToken = $0 }
                SecretTextField(label: "App Token (xapp-)", value: viewModel.appToken) { viewModel.appToken = $0 }
                EditableTextField(label: "Allowed User IDs", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
            }

            SettingsSection(title: "Home Channel", icon: "house") {
                EditableTextField(label: "Channel ID", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
                EditableTextField(label: "Display Name", value: viewModel.homeChannelName) { viewModel.homeChannelName = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Require @mention", isOn: viewModel.requireMention) { viewModel.requireMention = $0 }
                PickerRow(label: "Reply Mode", selection: viewModel.replyToMode, options: viewModel.replyToModeOptions) { viewModel.replyToMode = $0 }
                ToggleRow(label: "Reply in thread", isOn: viewModel.replyInThread) { viewModel.replyInThread = $0 }
                ToggleRow(label: "Reply broadcast", isOn: viewModel.replyBroadcast) { viewModel.replyBroadcast = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create a Slack app at api.slack.com/apps, enable Socket Mode, grant bot scopes (chat:write, app_mentions:read, channels:history, etc.), then copy the Bot User OAuth Token (xoxb-) and the App-Level Token (xapp-).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open Slack API") { PlatformSetupHelpers.openURL("https://api.slack.com/apps") }
                    .controlSize(.small)
                Button("Slack Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack") }
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
