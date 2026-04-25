import SwiftUI
import ScarfCore
import ScarfDesign

struct SignalSetupView: View {
    @State private var viewModel: SignalSetupViewModel
    init(context: ServerContext) { _viewModel = State(initialValue: SignalSetupViewModel(context: context)) }


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions
            prerequisiteStatus

            SettingsSection(title: "Daemon Endpoint", icon: "network") {
                EditableTextField(label: "HTTP URL", value: viewModel.httpURL) { viewModel.httpURL = $0 }
                EditableTextField(label: "Account (E.164)", value: viewModel.account) { viewModel.account = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                ToggleRow(label: "Allow All Users", isOn: viewModel.allowAllUsers) { viewModel.allowAllUsers = $0 }
                if !viewModel.allowAllUsers {
                    EditableTextField(label: "Allowed Users", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                }
                EditableTextField(label: "Group Allowed Users", value: viewModel.groupAllowedUsers) { viewModel.groupAllowedUsers = $0 }
                EditableTextField(label: "Home Channel", value: viewModel.homeChannel) { viewModel.homeChannel = $0 }
            }

            saveBar
            Divider()
            terminalSection
        }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.stopTerminal() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signal integration requires signal-cli (Java-based) installed locally. Link this Mac as a Signal device, then keep the daemon running so hermes can send/receive messages.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Install signal-cli") { PlatformSetupHelpers.openURL("https://github.com/AsamK/signal-cli/wiki/Quickstart") }
                    .controlSize(.small)
                Button("Signal Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/signal") }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var prerequisiteStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.signalCLIInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.signalCLIInstalled ? .green : .orange)
            (viewModel.signalCLIInstalled
                ? Text("signal-cli is available on PATH")
                : Text("signal-cli not found on PATH — install it first"))
                .font(.caption)
                .foregroundStyle(viewModel.signalCLIInstalled ? Color.primary : Color.orange)
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var saveBar: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reload") { viewModel.load() }.controlSize(.small)
            Button("Save") { viewModel.save() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
        }
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("signal-cli Terminal", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                switch viewModel.activeTask {
                case .none:
                    Button("Link Device") { viewModel.startLink() }.controlSize(.small)
                        .disabled(!viewModel.signalCLIInstalled)
                    Button("Start Daemon") { viewModel.startDaemon() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
                        .disabled(!viewModel.signalCLIInstalled || viewModel.account.isEmpty)
                case .link:
                    Text("Linking…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { viewModel.stopTerminal() }.controlSize(.small)
                case .daemon:
                    Text("Daemon running").font(.caption).foregroundStyle(.green)
                    Button("Stop") { viewModel.stopTerminal() }.controlSize(.small)
                }
            }
            Text("Link the device first to generate and scan a QR code. Once linked, start the daemon — it must keep running for hermes to send/receive messages.")
                .font(.caption)
                .foregroundStyle(.secondary)
            EmbeddedSetupTerminal(controller: viewModel.terminalController)
                .frame(minHeight: 260, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
