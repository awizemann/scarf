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
    let config: IOSServerConfig
    let key: SSHKeyBundle
    let onDisconnect: @MainActor () async -> Void

    /// Stable context UUID shared with DashboardView + ChatView.
    /// Matches the prior convention so the CitadelServerTransport
    /// connection pool reuses the same SSH client across tabs.
    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    var body: some View {
        let ctx = config.toServerContext(id: Self.sharedContextID)
        TabView {
            // 1 — Chat: the reason the app is on your phone. Primary
            // tab; opens straight into the chat surface.
            NavigationStack {
                ChatView(config: config, key: key)
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }

            // 2 — Dashboard: stats + recent sessions (no surfaces list
            // anymore — those live in More).
            NavigationStack {
                DashboardView(config: config, key: key)
            }
            .tabItem {
                Label("Dashboard", systemImage: "gauge.with.needle")
            }

            // 3 — Memory: MEMORY.md + USER.md + SOUL.md.
            NavigationStack {
                MemoryListView(config: config)
            }
            .tabItem {
                Label("Memory", systemImage: "brain.head.profile")
            }

            // 4 — More: Cron, Skills, Settings, plus the destructive
            // "Forget this server" action. Named "More" because on
            // iOS 18 with .sidebarAdaptable the system collapses
            // leftover tabs into a disclosure group with that exact
            // label automatically; choosing the same word keeps our
            // More tab visually consistent with the system default.
            NavigationStack {
                MoreTab(config: config, onDisconnect: onDisconnect)
            }
            .tabItem {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        // Pulls the sidebar-on-iPad affordance into the same code path
        // as the bottom-bar-on-iPhone one. No-op on iPhone today.
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.serverContext, ctx)
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
    let onDisconnect: @MainActor () async -> Void

    @State private var showForgetConfirmation = false
    @State private var isForgetting = false

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
                NavigationLink {
                    SkillsListView(config: config)
                } label: {
                    Label("Skills", systemImage: "sparkles")
                }
                NavigationLink {
                    SettingsView(config: config)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
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
                .disabled(isForgetting)
            } footer: {
                Text("Removes this server's SSH key and host info from the device. You'll need to add the public key back to `~/.ssh/authorized_keys` to reconnect.")
                    .font(.caption)
            }
        }
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
                    await onDisconnect()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your SSH key and host settings will be removed from this device. This cannot be undone.")
        }
    }
}
