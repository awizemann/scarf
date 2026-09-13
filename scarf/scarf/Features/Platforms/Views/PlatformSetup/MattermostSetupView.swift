import SwiftUI
import ScarfCore
import ScarfDesign

struct MattermostSetupView: View {
    @State private var viewModel: MattermostSetupViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: MattermostSetupViewModel(context: context))
    }


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

            // v0.13 Messaging Gateway behavior — self-hides on pre-v0.13.
            GatewayBehaviorSection(
                platform: "mattermost",
                capabilities: capabilitiesStore?.capabilities ?? .empty,
                context: context
            )
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
}
