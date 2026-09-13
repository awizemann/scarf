import SwiftUI
import ScarfCore
import ScarfDesign

/// SimpleX Chat setup form. SimpleX (v0.14, 22nd platform) had no form until
/// now; v0.17 added group-allowlist + auto-accept controls. Connects to a local
/// `simplex-chat` daemon over WebSocket; all config is `.env`.
struct SimpleXSetupView: View {
    @State private var viewModel: SimpleXSetupViewModel
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: SimpleXSetupViewModel(context: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Daemon", icon: "network") {
                EditableTextField(label: "WebSocket URL", value: viewModel.wsURL) { viewModel.wsURL = $0 }
            }

            SettingsSection(title: "Access", icon: "person.crop.circle.badge.checkmark") {
                ToggleRow(label: "Allow all contacts (dev only)", isOn: viewModel.allowAllUsers) { viewModel.allowAllUsers = $0 }
                if !viewModel.allowAllUsers {
                    EditableTextField(label: "Allowed Contacts", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                }
                EditableTextField(label: "Allowed Groups", value: viewModel.groupAllowed) { viewModel.groupAllowed = $0 }
                ToggleRow(label: "Auto-accept contact requests", isOn: viewModel.autoAccept) { viewModel.autoAccept = $0 }
            }

            SettingsSection(title: "Optional", icon: "slider.horizontal.3") {
                EditableTextField(label: "Home Channel", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
                EditableTextField(label: "Home Channel Name", value: viewModel.homeChannelName) { viewModel.homeChannelName = $0 }
                EditableTextField(label: "Text Batch Delay (s)", value: viewModel.textBatchDelay) { viewModel.textBatchDelay = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SimpleX has no user accounts or servers — the agent talks to a local `simplex-chat` daemon over WebSocket. Start the daemon (e.g. `simplex-chat -p 5225`) and point the WebSocket URL at it. Leave 'Allowed Groups' empty to ignore group messages (safer default).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("SimpleX Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/simplex") }
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
