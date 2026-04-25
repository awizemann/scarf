import SwiftUI
import ScarfCore
import ScarfDesign

struct EmailSetupView: View {
    @State private var viewModel: EmailSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: EmailSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions
            presetBar

            SettingsSection(title: "Credentials", icon: "envelope") {
                EditableTextField(label: "Email Address", value: viewModel.address) { viewModel.address = $0 }
                SecretTextField(label: "App Password", value: viewModel.password) { viewModel.password = $0 }
            }

            SettingsSection(title: "Servers", icon: "server.rack") {
                EditableTextField(label: "IMAP Host", value: viewModel.imapHost) { viewModel.imapHost = $0 }
                EditableTextField(label: "SMTP Host", value: viewModel.smtpHost) { viewModel.smtpHost = $0 }
                EditableTextField(label: "IMAP Port", value: viewModel.imapPort) { viewModel.imapPort = $0 }
                EditableTextField(label: "SMTP Port", value: viewModel.smtpPort) { viewModel.smtpPort = $0 }
                EditableTextField(label: "Poll Interval (s)", value: viewModel.pollInterval) { viewModel.pollInterval = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                ToggleRow(label: "Allow All Senders", isOn: viewModel.allowAllUsers) { viewModel.allowAllUsers = $0 }
                if !viewModel.allowAllUsers {
                    EditableTextField(label: "Allowed Senders", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                }
                EditableTextField(label: "Home Address", value: viewModel.homeAddress) { viewModel.homeAddress = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Skip Attachments", isOn: viewModel.skipAttachments) { viewModel.skipAttachments = $0 }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enable 2FA on your email account and generate an app password. Regular account passwords will fail. Always set allowed senders — otherwise anyone knowing the address can message the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Email Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/email") }
                    .controlSize(.small)
            }
        }
    }

    private var presetBar: some View {
        HStack(spacing: 8) {
            Text("Preset:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(viewModel.presets, id: \.name) { preset in
                Button(preset.name) { viewModel.applyPreset(preset) }
                    .controlSize(.small)
            }
            Spacer()
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
            Button("Save") { viewModel.save() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
        }
    }
}
