import SwiftUI
import ScarfCore
import ScarfDesign

struct TelegramSetupView: View {
    @State private var viewModel: TelegramSetupViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: TelegramSetupViewModel(context: context))
    }


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
                ToggleRow(label: "Disable topic auto-rename", isOn: viewModel.disableTopicAutoRename) { viewModel.disableTopicAutoRename = $0 }
                // v0.15 <= host < v0.21.1: Hermes deleted the reader at
                // v0.21.1, so on a newer host this toggle would promise a
                // behaviour nothing implements. The VALUE is still PARSED on
                // every host (see `TelegramSettings.ignoreRootDM`) but only
                // WRITTEN inside the window, so the stored setting survives
                // untouched and downgrading brings it back.
                if capabilitiesStore?.capabilities.hasTelegramIgnoreRootDM ?? true {
                    ToggleRow(label: "Ignore root DM", isOn: viewModel.ignoreRootDM) { viewModel.ignoreRootDM = $0 }
                }
                if capabilitiesStore?.capabilities.hasTelegramRichMessages ?? false {
                    ToggleRow(label: "Rich messages (Bot API 10.1)", isOn: viewModel.richMessages) { viewModel.richMessages = $0 }
                    ToggleRow(label: "Online/offline status", isOn: viewModel.statusIndicator) { viewModel.statusIndicator = $0 }
                }
            }

            SettingsSection(title: "Webhook (advanced)", icon: "arrow.up.right.square") {
                EditableTextField(label: "Webhook URL", value: viewModel.webhookURL) { viewModel.webhookURL = $0 }
                EditableTextField(label: "Webhook Port", value: viewModel.webhookPort) { viewModel.webhookPort = $0 }
                SecretTextField(label: "Webhook Secret", value: viewModel.webhookSecret) { viewModel.webhookSecret = $0 }
            }

            saveBar

            // v0.13 Messaging Gateway behavior — self-hides on pre-v0.13.
            GatewayBehaviorSection(
                platform: "telegram",
                capabilities: capabilitiesStore?.capabilities ?? .empty,
                context: context
            )
        }
        .onAppear { viewModel.load(capabilities: capabilitiesStore?.capabilities ?? .empty) }
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
            OutcomeMessageBar(
                text: viewModel.message,
                kind: viewModel.messageKind,
                onDismiss: { viewModel.dismissMessage() }
            )
            Spacer()
            Button("Reload") { viewModel.load(capabilities: capabilitiesStore?.capabilities ?? .empty) }
                .controlSize(.small)
                .disabled(viewModel.isBusy)
            Button("Save") { viewModel.save() }
                .buttonStyle(ScarfPrimaryButton())
                .controlSize(.small)
                // Disabled until the (now off-main, C10) load has landed:
                // `saveForm` treats a blank field as an unset, so a Save from
                // the pre-load blanks would comment live keys out of `.env`.
                .disabled(viewModel.isBusy)
        }
    }
}
