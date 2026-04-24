import SwiftUI
import ScarfCore
import ScarfIOS

/// App entry point. Renders a single `WindowGroup` whose root decides
/// between onboarding and the connected-app surface based on whether
/// a `IOSServerConfig` + `SSHKeyBundle` pair is already stored.
@main
struct ScarfIOSApp: App {
    @State private var root = RootModel(
        keyStore: KeychainSSHKeyStore(),
        configStore: UserDefaultsIOSServerConfigStore()
    )

    init() {
        // Wire ScarfCore's transport factory to produce Citadel-backed
        // `ServerTransport`s for every `.ssh` context. Without this,
        // `ServerContext.makeTransport()` would fall back to the
        // Mac-only `SSHTransport` which shells out to `/usr/bin/ssh`
        // — not present on iOS.
        //
        // Each call builds a fresh `CitadelServerTransport`. The
        // transport itself lazily opens + caches a single long-lived
        // SSH connection internally, so the per-call overhead is
        // just the factory invocation, not a new SSH handshake.
        ServerContext.sshTransportFactory = { id, config, displayName in
            CitadelServerTransport(
                contextID: id,
                config: config,
                displayName: displayName,
                keyProvider: {
                    // The transport needs the SSH key every time it
                    // (re)opens an SSH session. We re-read from the
                    // Keychain each time rather than caching in memory
                    // so Keychain-level access controls (After First
                    // Unlock) are honoured.
                    let store = KeychainSSHKeyStore()
                    guard let key = try await store.load() else {
                        throw SSHKeyStoreError.backendFailure(
                            message: "No SSH key in Keychain — re-run onboarding.",
                            osStatus: nil
                        )
                    }
                    return key
                }
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: root)
                .task { await root.load() }
                // Clamp Dynamic Type at the scene root. ScarfGo is a
                // developer tool that needs more density than Apple's
                // .xxxLarge default, but we still scale from .xSmall
                // to .accessibility2 so users who need larger text can
                // get it without breaking the layout. Going past
                // .accessibility2 (~XL accessibility) collapses
                // multi-column rows and forces text truncation — not
                // a win for anyone. Cross-checked against
                // Use-Your-Loaf's "Restricting Dynamic Type Sizes"
                // guidance (M8 density research).
                .dynamicTypeSize(.xSmall ... .accessibility2)
        }
    }
}

/// Decides whether the user needs to onboard or can see the Dashboard.
@Observable
@MainActor
final class RootModel {
    enum State {
        case loading
        case onboarding
        case connected(IOSServerConfig, SSHKeyBundle)
    }

    private(set) var state: State = .loading

    private let keyStore: any SSHKeyStore
    private let configStore: any IOSServerConfigStore

    init(keyStore: any SSHKeyStore, configStore: any IOSServerConfigStore) {
        self.keyStore = keyStore
        self.configStore = configStore
    }

    func load() async {
        do {
            let key = try await keyStore.load()
            let cfg = try await configStore.load()
            if let key, let cfg {
                state = .connected(cfg, key)
            } else {
                state = .onboarding
            }
        } catch {
            // Corrupted state → re-onboard. Logging would go here.
            state = .onboarding
        }
    }

    /// Called from OnboardingView when the flow reaches `.connected`.
    /// Re-reads the stores and flips the root state.
    func onboardingFinished() async {
        await load()
    }

    /// Called from Dashboard "Disconnect" to wipe state and restart onboarding.
    func disconnect() async {
        try? await keyStore.delete()
        try? await configStore.delete()
        state = .onboarding
    }
}

struct RootView: View {
    let model: RootModel

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading…")
        case .onboarding:
            OnboardingRootView(onFinished: {
                await model.onboardingFinished()
            })
        case .connected(let config, let key):
            DashboardView(
                config: config,
                key: key,
                onDisconnect: {
                    await model.disconnect()
                }
            )
        }
    }
}
