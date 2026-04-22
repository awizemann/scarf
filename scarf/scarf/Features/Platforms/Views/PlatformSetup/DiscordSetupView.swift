import SwiftUI
import ScarfCore

struct DiscordSetupView: View {
    @State private var viewModel: DiscordSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: DiscordSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Required", icon: "key") {
                SecretTextField(label: "Bot Token", value: viewModel.botToken) { viewModel.botToken = $0 }
                EditableTextField(label: "Allowed User IDs", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
            }

            SettingsSection(title: "Home Channel", icon: "house") {
                EditableTextField(label: "Home Channel ID", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
                EditableTextField(label: "Display Name", value: viewModel.homeChannelName) { viewModel.homeChannelName = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Require @mention", isOn: viewModel.requireMention) { viewModel.requireMention = $0 }
                EditableTextField(label: "Free-Response Channels", value: viewModel.freeResponseChannels) { viewModel.freeResponseChannels = $0 }
                ToggleRow(label: "Auto-thread on mention", isOn: viewModel.autoThread) { viewModel.autoThread = $0 }
                ToggleRow(label: "Reactions", isOn: viewModel.reactions) { viewModel.reactions = $0 }
                PickerRow(label: "Allow Other Bots", selection: viewModel.allowBots, options: viewModel.allowBotsOptions) { viewModel.allowBots = $0 }
                PickerRow(label: "Reply Mode", selection: viewModel.replyToMode, options: viewModel.replyToModeOptions) { viewModel.replyToMode = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create an app in Discord's Developer Portal, enable Message Content and Server Members intents, and copy the bot token. Invite the bot to your server via the OAuth2 URL generator.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open Developer Portal") { PlatformSetupHelpers.openURL("https://discord.com/developers/applications") }
                    .controlSize(.small)
                Button("Discord Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/discord") }
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
