import SwiftUI
import ScarfCore
import ScarfDesign

struct WebhookSetupView: View {
    @State private var viewModel: WebhookSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: WebhookSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Global Settings", icon: "arrow.up.right.square") {
                ToggleRow(label: "Webhook Enabled", isOn: viewModel.enabled) { viewModel.enabled = $0 }
                EditableTextField(label: "Port", value: viewModel.port) { viewModel.port = $0 }
                SecretTextField(label: "HMAC Secret", value: viewModel.secret) { viewModel.secret = $0 }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Per-route subscriptions (events, prompt template, delivery target) are managed in the Webhooks sidebar — not here. This panel only controls whether the webhook platform is listening at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enable the webhook platform to accept event-driven agent triggers. The HMAC secret is used as a fallback when individual routes don't provide their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Webhook Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks") }
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
