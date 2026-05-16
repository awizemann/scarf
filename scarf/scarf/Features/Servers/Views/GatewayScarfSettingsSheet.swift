import SwiftUI
import ScarfCore
import ScarfDesign

/// HTTP gateway configuration sheet. This deliberately avoids SSH wording:
/// the user pastes a Gateway Scarf URL plus bearer token, and Scarf writes the
/// config file consumed by `GatewayScarfConnectionConfig.load()`.
struct GatewayScarfSettingsSheet: View {
    @State private var viewModel = GatewayScarfSettingsViewModel()
    @Environment(\.dismiss) private var dismiss

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
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        HStack {
            Image(systemName: "network")
                .font(.title2)
            Text("Gateway Scarf")
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

            LabeledGatewayField("Gateway URL") {
                TextField("http://192.168.1.198:8765", text: $viewModel.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            LabeledGatewayField("Bearer token") {
                SecureField("Token from ~/.secrets/gateway-scarf-token", text: $viewModel.token)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Text("Scarf will talk to Gateway Scarf over HTTP instead of opening an SSH connection. The token is stored locally in Application Support with owner-only permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        Text("Test Gateway")
                    }
                }
                .disabled(viewModel.isTesting || !viewModel.canSave)
            }

            if let result = viewModel.testResult {
                switch result {
                case .success(let serviceName, let hermesVersion, let capabilities):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(serviceName).font(.caption.monospaced())
                        Text(hermesVersion).font(.caption).foregroundStyle(.secondary)
                        Text(capabilities).font(.caption).foregroundStyle(.secondary)
                    }
                case .failure(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Gateway test failed", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let saveError = viewModel.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                do {
                    try viewModel.save()
                    dismiss()
                } catch {
                    // saveError is populated by the view model.
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canSave || viewModel.isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct LabeledGatewayField<Content: View>: View {
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
