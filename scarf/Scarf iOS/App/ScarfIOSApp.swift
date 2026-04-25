import SwiftUI
import ScarfCore
import ScarfIOS
import os

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
                .task {
                    // Best-effort notification setup. Harmless if the
                    // user denies — we just don't get push. The Push
                    // Notifications capability is NOT enabled in the
                    // Xcode target yet (M9 #4.4 skeleton only), so
                    // APNs device-token registration is commented out
                    // inside setUpOnLaunch — the delegate + category
                    // plumbing is otherwise ready to light up when
                    // Hermes gains a push sender.
                    await MainActor.run { NotificationRouter.shared.setUpOnLaunch() }
                }
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

    /// Most recent non-fatal failure surfaced from RootModel operations
    /// (load, connect, forget). The ServerListView renders a banner above
    /// the list when this is non-nil with a Retry/Dismiss affordance.
    /// `nil` after a successful op so stale errors don't linger.
    var lastError: String?

    private let keyStore: any SSHKeyStore
    private let configStore: any IOSServerConfigStore

    private static let logger = Logger(
        subsystem: "com.scarf.ios",
        category: "RootModel"
    )

    init(keyStore: any SSHKeyStore, configStore: any IOSServerConfigStore) {
        self.keyStore = keyStore
        self.configStore = configStore
    }

    /// Clear the surfaced error. Called by the ServerListView banner's
    /// Dismiss button.
    func clearLastError() {
        lastError = nil
    }

    /// Load configured servers from disk and pick an initial state.
    func load() async {
        do {
            let all = try await configStore.listAll()
            servers = all
            lastError = nil
            if all.isEmpty {
                // Fresh install or user forgot every server → go
                // straight to onboarding with a new ID reserved so
                // completion writes under the right slot.
                state = .onboarding(forNewServer: ServerID())
            } else {
                state = .serverList
            }
        } catch {
            // configStore is UserDefaults-backed; failures here are
            // exceptional (corrupted v2 blob, JSONDecoder error). Surface
            // the error to the user but recover into onboarding so they
            // aren't permanently locked out of the app — the state is
            // unsalvageable, the user needs to re-onboard anyway.
            Self.logger.error("RootModel.load failed: \(error.localizedDescription, privacy: .public)")
            servers = [:]
            lastError = "Couldn't load saved servers (\(error.localizedDescription)). Starting fresh."
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
        do {
            var diskConfig: IOSServerConfig? = servers[id]
            if diskConfig == nil {
                diskConfig = try await configStore.load(id: id)
            }
            let diskKey: SSHKeyBundle? = try await keyStore.load(for: id)
            guard let config = diskConfig, let key = diskKey else {
                // Genuine "no row" / "no key" — preserve the pre-A.3
                // behaviour: re-onboard under this ID so the user keeps
                // host/user/port and just regenerates the key.
                state = .onboarding(forNewServer: id)
                return
            }
            lastError = nil
            state = .connected(id, config, key)
        } catch {
            // Transient Keychain errors (biometric cancel, device
            // locked, OS-level Keychain corruption) used to drop the
            // user into fresh onboarding — destroying useful state.
            // Now we keep them on the server list with a banner so
            // they can retry once the Keychain is reachable again.
            Self.logger.error(
                "RootModel.connect failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            lastError = "Couldn't unlock server credentials: \(error.localizedDescription)"
            state = .serverList
        }
    }

    /// Soft disconnect: return to the server list without wiping
    /// credentials. Per-view controllers (ChatController,
    /// IOSDashboardViewModel, etc.) tear down their transports via
    /// SwiftUI `.onDisappear` when ScarfGoTabRoot unmounts; on next
    /// connect we get fresh transports. We also flush the shared
    /// UserHomeCache entry for the server we're leaving so a future
    /// reconnect doesn't reuse a stale `$HOME` probe (minor, but
    /// matters if the remote user's home directory changed — rare
    /// but possible on shared hosts).
    func softDisconnect() async {
        if case .connected(let id, _, _) = state {
            await ServerContext.invalidateCachedHome(forServerID: id)
        }
        state = .serverList
    }

    /// Hard forget: wipe the specified server's key + config, refresh
    /// the list, transition to serverList (or onboarding if empty).
    /// Per-store failures are captured in `lastError` so a partial
    /// forget surfaces a banner instead of silently leaving orphans.
    func forget(id: ServerID) async {
        var failures: [String] = []
        do {
            try await keyStore.delete(for: id)
        } catch {
            Self.logger.error(
                "RootModel.forget keyStore.delete failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            failures.append("Keychain: \(error.localizedDescription)")
        }
        do {
            try await configStore.delete(id: id)
        } catch {
            Self.logger.error(
                "RootModel.forget configStore.delete failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            failures.append("Config: \(error.localizedDescription)")
        }
        // Reload from disk so in-memory state reflects what's actually
        // persisted — covers the partial-failure case where Keychain
        // succeeded but config didn't (or vice versa).
        servers = (try? await configStore.listAll()) ?? [:]
        if failures.isEmpty {
            lastError = nil
        } else {
            lastError = "Couldn't fully forget server: " + failures.joined(separator: "; ")
        }
        state = servers.isEmpty ? .onboarding(forNewServer: ServerID()) : .serverList
    }

    /// Legacy v1 "Disconnect" that wipes EVERYTHING. Kept for back-compat
    /// with any caller that still hits the no-arg path (there shouldn't
    /// be any after 3.5 lands, but the protocol still supports it).
    /// Same partial-failure semantics as `forget(id:)`.
    func disconnect() async {
        var failures: [String] = []
        do {
            try await keyStore.delete()
        } catch {
            Self.logger.error("RootModel.disconnect keyStore.delete failed: \(error.localizedDescription, privacy: .public)")
            failures.append("Keychain: \(error.localizedDescription)")
        }
        do {
            try await configStore.delete()
        } catch {
            Self.logger.error("RootModel.disconnect configStore.delete failed: \(error.localizedDescription, privacy: .public)")
            failures.append("Config: \(error.localizedDescription)")
        }
        servers = (try? await configStore.listAll()) ?? [:]
        if !failures.isEmpty {
            lastError = "Couldn't fully sign out: " + failures.joined(separator: "; ")
        }
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
