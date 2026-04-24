import SwiftUI
import ScarfCore
import ScarfIOS

/// ScarfGo's primary navigation surface. Replaces the pre-M8
/// "Dashboard is the hub" pattern where Chat/Memory/Cron/Skills/
/// Settings lived as NavigationLink rows three-quarters of the way
/// down a scrolling List — pass-1 user-visible complaint:
///
/// > "We should have the actions for the user in a permanent footer?
/// >  I don't see any navigation."
///
/// 4 primary tabs + a "More" bucket for the read-heavy / seldom-used
/// features. Uses iOS 18's `.sidebarAdaptable` tab style so the same
/// tree degrades to a bottom tab bar on iPhone and gets a native
/// sidebar on iPadOS / macCatalyst if we ever add those targets.
///
/// Each tab wraps its feature view in its own `NavigationStack` so
/// push navigation (Cron editor, Memory detail, etc.) stays scoped
/// to the tab instead of bleeding across.
struct ScarfGoTabRoot: View {
    let serverID: ServerID
    let config: IOSServerConfig
    let key: SSHKeyBundle
    let onSoftDisconnect: @MainActor () async -> Void
    let onForget: @MainActor () async -> Void

    /// One coordinator per server-connected session. Cross-tab
    /// signalling (Dashboard row → Chat tab resume, eventually
    /// notification deep-link → Chat) flows through here.
    @State private var coordinator = ScarfGoCoordinator()

    var body: some View {
        // The transport factory is keyed by ServerID, so the correct
        // Keychain slot + config is picked automatically. Reuses the
        // server's own id as the context id so the CitadelServerTransport
        // pool caches per-server (instead of the singleton we had
        // pre-M9). Two active servers → two connection holders, no
        // SSH channel contention.
        let ctx = config.toServerContext(id: serverID)
        TabView(selection: $coordinator.selectedTab) {
            // 1 — Chat: the reason the app is on your phone. Primary
            // tab; opens straight into the chat surface.
            NavigationStack {
                ChatView(config: config, key: key)
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(ScarfGoCoordinator.Tab.chat)

            // 2 — Dashboard: stats + recent sessions (no surfaces list
            // anymore — those live in More).
            NavigationStack {
                DashboardView(config: config, key: key)
            }
            .tabItem {
                Label("Dashboard", systemImage: "gauge.with.needle")
            }
            .tag(ScarfGoCoordinator.Tab.dashboard)

            // 3 — Memory: MEMORY.md + USER.md + SOUL.md.
            NavigationStack {
                MemoryListView(config: config)
            }
            .tabItem {
                Label("Memory", systemImage: "brain.head.profile")
            }
            .tag(ScarfGoCoordinator.Tab.memory)

            // 4 — More: Cron, Skills, Settings, plus the destructive
            // "Forget this server" action. Named "More" because on
            // iOS 18 with .sidebarAdaptable the system collapses
            // leftover tabs into a disclosure group with that exact
            // label automatically; choosing the same word keeps our
            // More tab visually consistent with the system default.
            NavigationStack {
                MoreTab(
                    config: config,
                    onSoftDisconnect: onSoftDisconnect,
                    onForget: onForget
                )
            }
            .tabItem {
                Label("More", systemImage: "ellipsis.circle")
            }
            .tag(ScarfGoCoordinator.Tab.more)
        }
        // Pulls the sidebar-on-iPad affordance into the same code path
        // as the bottom-bar-on-iPhone one. No-op on iPhone today.
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.serverContext, ctx)
        .environment(\.scarfGoCoordinator, coordinator)
        .onAppear {
            // Give the notification router a handle to this session's
            // coordinator so notification-taps can route across tabs.
            // Weak ref — coordinator owns its own lifetime, router
            // just observes.
            NotificationRouter.shared.coordinator = coordinator
        }
    }
}

/// Groups the features that don't deserve a primary tab on a phone:
/// Cron (infrequent edits), Skills (read-only), Settings (read-only
/// until M9 scoped editor), plus the destructive server-forget action.
///
/// Kept private to this file because we don't expect it to be reused
/// elsewhere — if a feature graduates to a primary tab, that's a
/// deliberate design decision.
private struct MoreTab: View {
    let config: IOSServerConfig
    let onSoftDisconnect: @MainActor () async -> Void
    let onForget: @MainActor () async -> Void

    @State private var showForgetConfirmation = false
    @State private var isForgetting = false
    @State private var isDisconnecting = false

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Host", value: config.host)
                if let user = config.user {
                    LabeledContent("User", value: user)
                }
                if let port = config.port {
                    LabeledContent("Port", value: String(port))
                }
            }

            Section("Features") {
                NavigationLink {
                    CronListView(config: config)
                } label: {
                    Label("Cron jobs", systemImage: "clock.arrow.circlepath")
                }
                .scarfGoCompactListRow()
                NavigationLink {
                    SkillsListView(config: config)
                } label: {
                    Label("Skills", systemImage: "sparkles")
                }
                .scarfGoCompactListRow()
                NavigationLink {
                    SettingsView(config: config)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .scarfGoCompactListRow()
            }

            Section {
                Button {
                    Task {
                        isDisconnecting = true
                        await onSoftDisconnect()
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
                .disabled(isDisconnecting || isForgetting)
            } footer: {
                Text("Closes the live connection. Your key and host details stay on this device; tapping the server from the list reconnects with no re-onboarding.")
                    .font(.caption)
            }

            Section {
                Button(role: .destructive) {
                    showForgetConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isForgetting {
                            ProgressView()
                        } else {
                            Text("Forget this server")
                        }
                        Spacer()
                    }
                }
                .disabled(isForgetting || isDisconnecting)
            } footer: {
                Text("Removes this server's SSH key and host info from the device. You'll need to add the public key back to `~/.ssh/authorized_keys` to reconnect.")
                    .font(.caption)
            }
        }
        .scarfGoListDensity()
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Forget this server?",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget \(config.displayName)", role: .destructive) {
                Task {
                    isForgetting = true
                    await onForget()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your SSH key and host settings for \(config.displayName) will be removed. Other servers stay configured. This cannot be undone.")
        }
    }
}
