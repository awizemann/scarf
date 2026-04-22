import SwiftUI
import ScarfCore

struct TelegramSetupView: View {
    @State private var viewModel: TelegramSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: TelegramSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Required", icon: "key") {
                SecretTextField(label: "Bot Token", value: viewModel.botToken) { viewModel.botToken = $0 }
                EditableTextField(label: "Allowed Users", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
            }

            SettingsSection(title: "Optional", icon: "slider.horizontal.3") {
                EditableTextField(label: "Home Channel", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
                ToggleRow(label: "Require @mention", isOn: viewModel.requireMention) { viewModel.requireMention = $0 }
                ToggleRow(label: "Reactions", isOn: viewModel.reactions) { viewModel.reactions = $0 }
            }

            SettingsSection(title: "Webhook (advanced)", icon: "arrow.up.right.square") {
                EditableTextField(label: "Webhook URL", value: viewModel.webhookURL) { viewModel.webhookURL = $0 }
                EditableTextField(label: "Webhook Port", value: viewModel.webhookPort) { viewModel.webhookPort = $0 }
                SecretTextField(label: "Webhook Secret", value: viewModel.webhookSecret) { viewModel.webhookSecret = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create a bot via @BotFather and get your numeric user ID from @userinfobot. Paste the token and your user ID below — the bot will only respond to allowed users.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Open BotFather") { PlatformSetupHelpers.openURL("https://t.me/BotFather") }
                    .controlSize(.small)
                Button("Telegram Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram") }
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
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
            Button("Save") { viewModel.save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
