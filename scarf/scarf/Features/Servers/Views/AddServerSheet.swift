import SwiftUI
import ScarfCore
import ScarfDesign

/// Sheet for adding a new remote server. Collects SSH connection details,
/// runs a "Test Connection" probe, and — on save — hands the persisted
/// `SSHConfig` (with `hermesBinaryHint` populated by the probe) to the
/// caller via the `onSave` closure.
struct AddServerSheet: View {
    @State private var viewModel = AddServerViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Called when the user confirms. Caller persists via `ServerRegistry`
    /// and typically switches the active window's context to the new server.
    let onSave: (_ displayName: String, _ config: SSHConfig) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    Divider()
                    testSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 680)
    }

    private var header: some View {
        HStack {
            Image(systemName: "server.rack")
                .font(.title2)
            Text("Add Remote Server")
                .scarfStyle(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection")
                .font(.subheadline).bold()
                .foregroundStyle(.secondary)

            LabeledField("Name") {
                TextField("Optional — defaults to hostname", text: $viewModel.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledField("Host") {
                TextField("hermes.example.com or a ~/.ssh/config alias", text: $viewModel.host)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledField("User") {
                TextField("Defaults to ~/.ssh/config or current user", text: $viewModel.user)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledField("Port") {
                TextField("22", text: $viewModel.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Spacer()
            }

            LabeledField("Identity file") {
                HStack(spacing: 8) {
                    TextField("ssh-agent (leave blank)", text: $viewModel.identityFile)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Choose…") { viewModel.pickIdentityFile() }
                }
            }

            LabeledField("Hermes data directory") {
                TextField("Default: ~/.hermes", text: $viewModel.remoteHome)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            Text("Leave blank unless Hermes is installed at a non-default path (systemd services often live at /var/lib/hermes/.hermes; Docker sidecars vary). Test Connection auto-suggests a value when it detects one of the known alternates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Scarf uses ssh-agent for authentication. If your key has a passphrase, run `ssh-add` before connecting — Scarf never prompts for or stores passphrases.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Probe").font(.subheadline).bold().foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    if viewModel.isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(viewModel.isTesting || !viewModel.canSave)
            }

            if let result = viewModel.testResult {
                switch result {
                case .success(let path, let dbFound, let suggestedHome):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("hermes at \(path)").font(.caption).monospaced()
                        if dbFound {
                            Text("state.db readable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let suggestion = suggestedHome {
                            // Scarf found Hermes data at one of the common
                            // alternate paths. One-click fill the
                            // remoteHome field so the user doesn't have to
                            // know this is a convention thing.
                            VStack(alignment: .leading, spacing: 4) {
                                Text("state.db not found at the default location, but Scarf found one at:")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                HStack {
                                    Text(suggestion)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("Use this") {
                                        viewModel.remoteHome = suggestion
                                    }
                                    .controlSize(.small)
                                }
                                .padding(8)
                                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            Text("state.db not found at the configured path. Either Hermes hasn't run yet on this server, or it's installed at a non-default location — set the Hermes data directory field above.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .failure(let message, let stderr, let command):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        DisclosureGroup("ssh trace") {
                            ScrollView {
                                Text(stderr.isEmpty ? "(no output)" : stderr)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 180)
                        }
                        .font(.caption)
                        DisclosureGroup("Command") {
                            ScrollView {
                                Text(command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(viewModel.resolvedDisplayName, viewModel.configForSave())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Form-field helper: label on the left, editable field on the right.
private struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            content
            Spacer(minLength: 0)
        }
    }
}
