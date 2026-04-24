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

/// Decides what screen ScarfGo shows. M9 added the `.serverList`
/// state so users can manage multiple servers instead of being
/// stuck with a single-server app. Transitions:
///
/// - `.loading` → `.serverList` when `load()` finds 1+ servers.
/// - `.loading` → `.onboarding(newID)` on fresh install.
/// - `.serverList` → `.onboarding(newID)` via the "+" button.
/// - `.serverList` → `.connected(id)` when the user taps a row.
/// - `.connected(id)` → `.serverList` via the "Disconnect" button
///    (soft — credentials kept).
/// - `.connected(id)` → `.serverList` via "Forget" (hard — wipes that
///    server's row from both stores).
/// - `.onboarding` → `.connected(newID)` on completion.
@Observable
@MainActor
final class RootModel {
    enum State: Equatable {
        case loading
        case serverList
        case onboarding(forNewServer: ServerID)
        case connected(ServerID, IOSServerConfig, SSHKeyBundle)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case (.serverList, .serverList): return true
            case (.onboarding(let a), .onboarding(let b)): return a == b
            case (.connected(let a, _, _), .connected(let b, _, _)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .loading
    /// Cached snapshot of all configured servers, keyed by ServerID.
    /// Published so ServerListView can render reactively without
    /// having to re-query stores on every re-render.
    private(set) var servers: [ServerID: IOSServerConfig] = [:]

    private let keyStore: any SSHKeyStore
    private let configStore: any IOSServerConfigStore

    init(keyStore: any SSHKeyStore, configStore: any IOSServerConfigStore) {
        self.keyStore = keyStore
        self.configStore = configStore
    }

    /// Load configured servers from disk and pick an initial state.
    func load() async {
        do {
            let all = try await configStore.listAll()
            servers = all
            if all.isEmpty {
                // Fresh install or user forgot every server → go
                // straight to onboarding with a new ID reserved so
                // completion writes under the right slot.
                state = .onboarding(forNewServer: ServerID())
            } else {
                state = .serverList
            }
        } catch {
            servers = [:]
            state = .onboarding(forNewServer: ServerID())
        }
    }

    /// Refresh the server list without disturbing `state`. Call from
    /// ServerListView `.task` on appear so just-added servers show up
    /// immediately.
    func refreshServers() async {
        servers = (try? await configStore.listAll()) ?? [:]
    }

    /// Start onboarding for a new server. The UI passes us the
    /// ServerID we reserved at that moment so the completion handler
    /// writes to the right slot.
    func beginAddServer() {
        state = .onboarding(forNewServer: ServerID())
    }

    /// Cancel an in-progress onboarding and return to the list.
    /// Called by the sheet's Cancel affordance.
    func cancelOnboarding() {
        state = servers.isEmpty ? .onboarding(forNewServer: ServerID()) : .serverList
    }

    /// Called from OnboardingView when the flow finishes. Reload the
    /// list and transition to `.connected` for the just-added server,
    /// or back to `.serverList` if we can't find it (defensive).
    func onboardingFinished(serverID: ServerID) async {
        servers = (try? await configStore.listAll()) ?? [:]
        if let config = servers[serverID],
           let key = try? await keyStore.load(for: serverID) {
            state = .connected(serverID, config, key)
        } else {
            state = .serverList
        }
    }

    /// Tap a server row → connect. Loads fresh from disk to catch any
    /// edits made through the Mac app (or future multi-device scenarios).
    func connect(to id: ServerID) async {
        var diskConfig: IOSServerConfig? = servers[id]
        if diskConfig == nil {
            diskConfig = try? await configStore.load(id: id)
        }
        let diskKey: SSHKeyBundle? = try? await keyStore.load(for: id)
        guard let config = diskConfig, let key = diskKey else {
            // Missing key → force re-onboarding under this ID so the
            // user can regenerate without losing host/user/port.
            state = .onboarding(forNewServer: id)
            return
        }
        state = .connected(id, config, key)
    }

    /// Soft disconnect: close any live transport but keep stored
    /// credentials. Returns to the server list so the user can tap
    /// another server (or the same one again).
    func softDisconnect() async {
        // Transport teardown is owned by ConnectedServerRegistry
        // (added in 3.3); for now the per-view controllers own their
        // own lifecycles via .onDisappear, so this is mostly a state
        // change. The registry commit will thread through here.
        state = .serverList
    }

    /// Hard forget: wipe the specified server's key + config, refresh
    /// the list, transition to serverList (or onboarding if empty).
    func forget(id: ServerID) async {
        try? await keyStore.delete(for: id)
        try? await configStore.delete(id: id)
        servers = (try? await configStore.listAll()) ?? [:]
        state = servers.isEmpty ? .onboarding(forNewServer: ServerID()) : .serverList
    }

    /// Legacy v1 "Disconnect" that wipes EVERYTHING. Kept for back-compat
    /// with any caller that still hits the no-arg path (there shouldn't
    /// be any after 3.5 lands, but the protocol still supports it).
    func disconnect() async {
        try? await keyStore.delete()
        try? await configStore.delete()
        servers = [:]
        state = .onboarding(forNewServer: ServerID())
    }
}

struct RootView: View {
    let model: RootModel

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading…")
        case .serverList:
            ServerListView(model: model)
        case .onboarding(let forNewServer):
            OnboardingRootView(targetServerID: forNewServer) {
                await model.onboardingFinished(serverID: forNewServer)
            } onCancel: {
                model.cancelOnboarding()
            }
        case .connected(let id, let config, let key):
            ScarfGoTabRoot(
                serverID: id,
                config: config,
                key: key,
                onSoftDisconnect: {
                    await model.softDisconnect()
                },
                onForget: {
                    await model.forget(id: id)
                }
            )
        }
    }
}
