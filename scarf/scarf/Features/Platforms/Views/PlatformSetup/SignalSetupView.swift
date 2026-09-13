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
                ToggleRow(label: "Require @mention (groups)", isOn: viewModel.requireMention) { viewModel.requireMention = $0 }
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

    /// Round-5 decision 15 gated the BUTTONS on `remotePairingNotice` and
    /// left this row alone — but the row is the same claim the buttons make,
    /// stated as a fact. `detectSignalCLI()` probes THIS Mac's login-shell
    /// PATH, so on a remote context "signal-cli is available on PATH" is a
    /// true sentence about the wrong machine, and the orange
    /// "install it first" is a false one: installing signal-cli here would
    /// change nothing, because the daemon and the link have to exist where
    /// Hermes runs. The row shows the host sentence the buttons already key
    /// on instead, which is the honest answer and the one the view model
    /// already computes (round-6 P53).
    @ViewBuilder
    private var prerequisiteStatus: some View {
        HStack(spacing: 8) {
            if let notice = viewModel.remotePairingNotice {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: viewModel.signalCLIInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(viewModel.signalCLIInstalled ? .green : .orange)
                (viewModel.signalCLIInstalled
                    ? Text("signal-cli is available on PATH")
                    : Text("signal-cli not found on PATH — install it first"))
                    .font(.caption)
                    .foregroundStyle(viewModel.signalCLIInstalled ? Color.primary : Color.orange)
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("signal-cli Terminal", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                switch viewModel.activeTask {
                case .none:
                    // Round-5 decision 15: the embedded terminal spawns on
                    // THIS Mac and writes the link into the LOCAL ~/.hermes,
                    // which a remote gateway never reads. `signalCLIInstalled`
                    // probes the local PATH, so on a remote context it is a
                    // fact about the wrong machine — the notice decides.
                    Button("Link Device") { viewModel.startLink() }.controlSize(.small)
                        .disabled(viewModel.remotePairingNotice != nil || !viewModel.signalCLIInstalled)
                    Button("Start Daemon") { viewModel.startDaemon() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
                        .disabled(viewModel.remotePairingNotice != nil || !viewModel.signalCLIInstalled || viewModel.account.isEmpty)
                case .link:
                    Text("Linking…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { viewModel.stopTerminal() }.controlSize(.small)
                case .daemon:
                    Text("Daemon running").font(.caption).foregroundStyle(.green)
                    Button("Stop") { viewModel.stopTerminal() }.controlSize(.small)
                }
            }
            if let notice = viewModel.remotePairingNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Link the device first to generate and scan a QR code. Once linked, start the daemon — it must keep running for hermes to send/receive messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EmbeddedSetupTerminal(controller: viewModel.terminalController)
                    .frame(minHeight: 260, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
