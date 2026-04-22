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

    var body: some Scene {
        WindowGroup {
            RootView(model: root)
                .task { await root.load() }
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
