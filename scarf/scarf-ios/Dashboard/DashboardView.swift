import SwiftUI
import ScarfCore
import ScarfIOS

/// Placeholder dashboard for M2. Shows the connected server and a
/// "Disconnect" affordance that wipes the stored key + config and
/// returns the user to onboarding.
///
/// **M3 replaces this** with a real dashboard backed by
/// `HermesDataService` running over a Citadel-backed transport.
/// For now this view just proves the "connected" state is reachable.
struct DashboardView: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle
    let onDisconnect: @MainActor () async -> Void

    @State private var isDisconnecting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connected to") {
                    LabeledContent("Display name", value: config.displayName)
                    LabeledContent("Host", value: config.host)
                    if let user = config.user {
                        LabeledContent("User", value: user)
                    }
                    if let port = config.port {
                        LabeledContent("Port", value: String(port))
                    }
                }

                Section("Device key") {
                    LabeledContent("Comment", value: key.comment)
                    LabeledContent("Fingerprint", value: key.displayFingerprint)
                    LabeledContent("Created", value: key.createdAt)
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            isDisconnecting = true
                            await onDisconnect()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isDisconnecting {
                                ProgressView()
                            } else {
                                Text("Disconnect")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDisconnecting)
                }

                Section {
                    Text("Dashboard data comes in M3 — this view is M2's \"hello, you're connected\" placeholder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(config.displayName)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
