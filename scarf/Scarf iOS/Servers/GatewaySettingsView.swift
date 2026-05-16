import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS Gateway Scarf setup. This mirrors the Mac sheet but is reachable from
/// the first-run server list, so a phone can be pointed at an existing Gateway
/// without going through SSH onboarding first.
struct GatewaySettingsView: View {
    let model: RootModel

    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var token: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: RootModel) {
        self.model = model
        let existing = model.gatewayConfig
        _baseURL = State(initialValue: existing?.baseURL.absoluteString ?? "")
        _token = State(initialValue: existing?.token ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.198:8765", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Bearer token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Gateway")
            } footer: {
                Text("ScarfGo will use Gateway Scarf over HTTP for files, process calls, and chat/ACP instead of opening SSH from iOS.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                }
            }
        }
        .navigationTitle("Gateway Scarf")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!canSave || isSaving)
            }
        }
    }

    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.configureGateway(baseURL: baseURL, token: token)
            dismiss()
        } catch let gateway as GatewayScarfClientError {
            switch gateway {
            case .invalidURL(let value): errorMessage = "Invalid gateway URL: \(value)"
            case .nonHTTPResponse: errorMessage = "Gateway did not return an HTTP response."
            case .httpStatus(let status, let message): errorMessage = "Gateway returned HTTP \(status): \(message)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
