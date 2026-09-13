import SwiftUI
import ScarfCore
import ScarfDesign

struct DiscordSetupView: View {
    @State private var viewModel: DiscordSetupViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: DiscordSetupViewModel(context: context))
    }


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
                if capabilitiesStore?.capabilities.hasDiscordHistoryBackfill == true {
                    ToggleRow(label: "Backfill channel history on join", isOn: viewModel.historyBackfill) { viewModel.historyBackfill = $0 }
                }
                // A WINDOW, not a floor: the Discord adapter stopped calling
                // its own `_discord_allow_any_attachment` getter at v2026.7.1
                // (0.18.0) and the key is a documented no-op at v2026.9.7, so
                // the row hides on a v0.18+ host — and keeps rendering, byte
                // for byte, on the v0.15–v0.17 hosts that honour it (C1).
                if capabilitiesStore?.capabilities.hasDiscordAllowAnyAttachment == true {
                    ToggleRow(label: "Allow any attachment type", isOn: viewModel.allowAnyAttachment) { viewModel.allowAnyAttachment = $0 }
                }
            }

            saveBar

            // v0.13 Messaging Gateway behavior — self-hides on pre-v0.13.
            // Discord's `allowed_channels` is a REAL allowlist
            // (plugins/platforms/discord/adapter.py:4620-4622, enforced at
            // :5675-5677, identical at v2026.8.31 and v2026.9.7); this is the
            // editor the v0.20.4 "KNOWN GAP" note was waiting for.
            GatewayBehaviorSection(
                platform: "discord",
                capabilities: capabilitiesStore?.capabilities ?? .empty,
                context: context
            )
        }
        .onAppear { viewModel.load(capabilities: capabilitiesStore?.capabilities ?? .empty) }
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
            OutcomeMessageBar(
                text: viewModel.message,
                kind: viewModel.messageKind,
                onDismiss: { viewModel.dismissMessage() }
            )
            Spacer()
            Button("Reload") { viewModel.load(capabilities: capabilitiesStore?.capabilities ?? .empty) }.controlSize(.small)
                    .disabled(viewModel.isBusy)
            Button("Save") { viewModel.save() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
                // Disabled until the (now off-main, C10) load has landed:
                // `saveForm` treats a blank field as an unset, so a Save from
                // the pre-load blanks would comment live keys out of `.env`.
                .disabled(viewModel.isBusy)
        }
    }
}
