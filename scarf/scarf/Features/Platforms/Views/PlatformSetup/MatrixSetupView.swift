import SwiftUI
import ScarfCore

struct MatrixSetupView: View {
    @State private var viewModel: MatrixSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: MatrixSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Homeserver", icon: "network") {
                EditableTextField(label: "Homeserver URL", value: viewModel.homeserver) { viewModel.homeserver = $0 }
            }

            SettingsSection(title: "Authentication", icon: "person.badge.key") {
                SecretTextField(label: "Access Token", value: viewModel.accessToken) { viewModel.accessToken = $0 }
                Text("— or use user/password login —")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                EditableTextField(label: "User ID", value: viewModel.userID) { viewModel.userID = $0 }
                SecretTextField(label: "Password", value: viewModel.password) { viewModel.password = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                EditableTextField(label: "Allowed Users", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                EditableTextField(label: "Home Room", value: viewModel.homeRoom) { viewModel.homeRoom = $0 }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                ToggleRow(label: "Require @mention", isOn: viewModel.requireMention) { viewModel.requireMention = $0 }
                ToggleRow(label: "Auto-thread on mention", isOn: viewModel.autoThread) { viewModel.autoThread = $0 }
                ToggleRow(label: "DM mention threads", isOn: viewModel.dmMentionThreads) { viewModel.dmMentionThreads = $0 }
            }

            SettingsSection(title: "End-to-End Encryption (experimental)", icon: "lock.shield") {
                ToggleRow(label: "Enable E2EE", isOn: viewModel.encryption) { viewModel.encryption = $0 }
                if viewModel.encryption {
                    SecretTextField(label: "Recovery Key", value: viewModel.recoveryKey) { viewModel.recoveryKey = $0 }
                }
            }

            saveBar
        }
        .onAppear { viewModel.load() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Matrix uses either an access token (preferred) or username/password. Get an access token from Element: Settings → Help & About → Access Token.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Matrix Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/matrix") }
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
