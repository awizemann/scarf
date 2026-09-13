import SwiftUI
import ScarfCore
import ScarfDesign

struct NtfySetupView: View {
    @State private var viewModel: NtfySetupViewModel
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: NtfySetupViewModel(context: context))
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Topic", icon: "bell.badge") {
                EditableTextField(label: "Topic", value: viewModel.topic) { viewModel.topic = $0 }
                EditableTextField(label: "Server URL", value: viewModel.server) { viewModel.server = $0 }
                EditableTextField(label: "Publish Topic", value: viewModel.publishTopic) { viewModel.publishTopic = $0 }
            }

            SettingsSection(title: "Authentication", icon: "key") {
                SecretTextField(label: "Token", value: viewModel.token) { viewModel.token = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Markdown formatting", isOn: viewModel.markdown) { viewModel.markdown = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Subscribe the agent to an ntfy topic on ntfy.sh or a self-hosted server. Set a separate publish topic if you want replies routed elsewhere. For protected topics, provide a token (Bearer) or user:pass (Basic).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("ntfy Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/ntfy") }
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
