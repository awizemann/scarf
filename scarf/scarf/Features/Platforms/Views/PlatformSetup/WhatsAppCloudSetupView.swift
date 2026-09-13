import SwiftUI
import ScarfCore
import ScarfDesign

/// WhatsApp Business Cloud API setup form (Hermes v0.17). Meta-hosted webhook
/// path — no bridge process. Distinct from the `whatsapp` web-bridge form.
struct WhatsAppCloudSetupView: View {
    @State private var viewModel: WhatsAppCloudSetupViewModel
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: WhatsAppCloudSetupViewModel(context: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Required", icon: "key") {
                EditableTextField(label: "Phone Number ID", value: viewModel.phoneNumberID) { viewModel.phoneNumberID = $0 }
                SecretTextField(label: "Access Token", value: viewModel.accessToken) { viewModel.accessToken = $0 }
            }

            SettingsSection(title: "Webhook", icon: "arrow.up.right.square") {
                SecretTextField(label: "Verify Token", value: viewModel.verifyToken) { viewModel.verifyToken = $0 }
                SecretTextField(label: "App Secret", value: viewModel.appSecret) { viewModel.appSecret = $0 }
                EditableTextField(label: "App ID", value: viewModel.appID) { viewModel.appID = $0 }
            }

            SettingsSection(title: "Optional", icon: "slider.horizontal.3") {
                EditableTextField(label: "WABA ID", value: viewModel.wabaID) { viewModel.wabaID = $0 }
                EditableTextField(label: "API Version", value: viewModel.apiVersion) { viewModel.apiVersion = $0 }
            }

            SettingsSection(title: "Direct-message allowlist", icon: "person.crop.circle.badge.checkmark") {
                PickerRow(label: "DM Policy", selection: viewModel.dmPolicy, options: viewModel.dmPolicyOptions) { viewModel.dmPolicy = $0 }
                if viewModel.dmPolicy == "allowlist" {
                    EditableTextField(label: "Allowed Senders", value: viewModel.allowFrom) { viewModel.allowFrom = $0 }
                }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect a WhatsApp Business number through Meta's hosted Cloud API (no bridge process). Create an app at Meta for Developers, add the WhatsApp product, then copy the Phone Number ID and a permanent access token. The verify token is any string you also set on the webhook; the app secret signs inbound webhooks. The DM allowlist restricts direct messages; group chats default to open (the bot replies in any group it's added to) — set `group_policy: allowlist` in config.yaml to restrict.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Meta for Developers") { PlatformSetupHelpers.openURL("https://developers.facebook.com/apps") }
                    .controlSize(.small)
                Button("WhatsApp Cloud Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp-cloud") }
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
