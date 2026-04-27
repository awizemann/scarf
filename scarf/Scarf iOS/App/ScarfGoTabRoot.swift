import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

/// ScarfGo's primary navigation surface. v2.5 expands the original
/// 4-tab layout (Chat | Dashboard | Memory | More) to 5 primary tabs
/// with Chat in the mathematical center:
///
///     Dashboard | Projects | Chat | Skills | System
///
/// "Chat in the middle" is the v2.5 product ask — chat is the action
/// users come back for, so it's the most thumb-reachable slot on a
/// phone-sized device. We stay on Apple's native `TabView` instead of
/// drawing a custom raised center button: 5 tabs is exactly the iPhone
/// system maximum (no auto-collapse to "More"), and `.sidebarAdaptable`
/// continues to give us a real sidebar on iPad / macCatalyst for free.
/// Memory drops out of primary slots and lives inside the renamed
/// "System" tab (was "More"). Skills graduates from a System sub-row
/// into its own primary tab to match v2.5's full Mac parity for skills
/// (Installed / Browse Hub / Updates).
///
/// Each tab wraps its feature view in its own `NavigationStack` so push
/// navigation (Cron editor, Memory detail, Project detail, etc.) stays
/// scoped to the tab instead of bleeding across.
struct ScarfGoTabRoot: View {
    let serverID: ServerID
    let config: IOSServerConfig
    let key: SSHKeyBundle
    let onSoftDisconnect: @MainActor () async -> Void
    let onForget: @MainActor () async -> Void

    /// One coordinator per server-connected session. Cross-tab
    /// signalling (Dashboard row → Chat tab resume, Project Detail
    /// → in-project chat handoff, notification deep-link → Chat) flows
    /// through here.
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
            // 1 — Dashboard: stats + recent sessions.
            NavigationStack {
                DashboardView(config: config, key: key, onSoftDisconnect: onSoftDisconnect)
            }
            .tabItem {
                Label("Dashboard", systemImage: "gauge.with.needle")
            }
            .tag(ScarfGoCoordinator.Tab.dashboard)
            .accessibilityLabel("Dashboard tab")

            // 2 — Projects: registered projects → per-project dashboard,
            // site, and sessions. Read-only registry on iOS — add /
            // rename / archive happens in the Mac app.
            NavigationStack {
                ProjectsListView(config: config)
            }
            .tabItem {
                Label("Projects", systemImage: "square.grid.2x2")
            }
            .tag(ScarfGoCoordinator.Tab.projects)
            .accessibilityLabel("Projects tab")

            // 3 — Chat: the reason the app is on your phone. Centered
            // among the 5 tabs for thumb reach + visual prominence.
            NavigationStack {
                ChatView(config: config, key: key)
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(ScarfGoCoordinator.Tab.chat)
            .accessibilityLabel("Chat tab")

            // 4 — Skills: Installed | Browse Hub | Updates, mirroring
            // the Mac app's 3-tab skills surface.
            NavigationStack {
                SkillsView(config: config)
            }
            .tabItem {
                Label("Skills", systemImage: "lightbulb")
            }
            .tag(ScarfGoCoordinator.Tab.skills)
            .accessibilityLabel("Skills tab")

            // 5 — System: server identity, Memory, Cron, Settings, plus
            // the destructive disconnect / forget actions. Renamed from
            // "More" to match the user-facing v2.5 vocabulary; the
            // .sidebarAdaptable system fallback label happens not to
            // matter here because we never overflow.
            NavigationStack {
                SystemTab(
                    config: config,
                    onSoftDisconnect: onSoftDisconnect,
                    onForget: onForget
                )
            }
            .tabItem {
                Label("System", systemImage: "gearshape.fill")
            }
            .tag(ScarfGoCoordinator.Tab.system)
            .accessibilityLabel("System tab")
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

/// Server identity + Memory + Cron + Settings + destructive actions.
/// "System" reads as configuration / server-meta; the reorganization
/// in v2.5 promotes Skills out of here into its own primary tab and
/// pulls Memory in from a primary tab into a NavigationLink row.
///
/// Kept private to this file because we don't expect it to be reused
/// elsewhere — if a feature graduates to a primary tab, that's a
/// deliberate design decision.
private struct SystemTab: View {
    let config: IOSServerConfig
    let onSoftDisconnect: @MainActor () async -> Void
    let onForget: @MainActor () async -> Void

    @State private var showForgetConfirmation = false
    @State private var isForgetting = false
    @State private var isDisconnecting = false
    /// Mirror of `SSHKeyICloudPreference.isEnabled` — drives the iCloud
    /// Keychain sync toggle (issue #52). Initial value is read on view
    /// init so the toggle reflects today's preference before the user
    /// taps anything; flipping triggers `migrateAllItems(toICloudSync:)`.
    @State private var iCloudSyncEnabled: Bool = SSHKeyICloudPreference.isEnabled
    @State private var iCloudMigrationInFlight = false
    @State private var iCloudMigrationError: String?

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Host", value: config.host)
                    .listRowBackground(ScarfColor.backgroundSecondary)
                if let user = config.user {
                    LabeledContent("User", value: user)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
                if let port = config.port {
                    LabeledContent("Port", value: String(port))
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
            }

            Section("Features") {
                NavigationLink {
                    MemoryListView(config: config)
                } label: {
                    Label("Memory", systemImage: "brain.head.profile")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
                NavigationLink {
                    CronListView(config: config)
                } label: {
                    Label("Cron jobs", systemImage: "clock.arrow.circlepath")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
                NavigationLink {
                    SettingsView(config: config)
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
            }

            Section {
                Toggle(isOn: $iCloudSyncEnabled) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.icloud.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync SSH key with iCloud Keychain")
                            Text(iCloudSyncEnabled
                                 ? "Synced — your other Apple devices with iCloud Keychain will see this key."
                                 : "This device only — generate a separate key on each device.")
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                    }
                }
                .tint(ScarfColor.accent)
                .disabled(iCloudMigrationInFlight)
                .onChange(of: iCloudSyncEnabled) { _, newValue in
                    Task {
                        iCloudMigrationInFlight = true
                        iCloudMigrationError = nil
                        defer { iCloudMigrationInFlight = false }
                        do {
                            try await KeychainSSHKeyStore().migrateAllItems(toICloudSync: newValue)
                        } catch {
                            // Revert the toggle on failure so the UI
                            // reflects what's actually in the Keychain;
                            // surface the error inline so the user can
                            // retry / report. Keychain failures here are
                            // rare (typically `errSecDuplicateItem` if a
                            // prior migration was interrupted — the
                            // delete-with-Any in writeBundle prevents
                            // that, but we still belt-and-brace).
                            iCloudMigrationError = error.localizedDescription
                            iCloudSyncEnabled = !newValue
                            SSHKeyICloudPreference.isEnabled = !newValue
                        }
                    }
                }
                if iCloudMigrationInFlight {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating Keychain…")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
                if let err = iCloudMigrationError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ScarfColor.warning)
                }
            } header: {
                Text("Security")
            } footer: {
                Text("End-to-end encrypted via iCloud Keychain. With Advanced Data Protection on, the encryption keys never leave your devices. Toggle off to keep the key device-only — each new device must onboard separately.")
                    .font(.caption)
            }
            .listRowBackground(ScarfColor.backgroundSecondary)

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
                .listRowBackground(ScarfColor.backgroundSecondary)
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
                .listRowBackground(ScarfColor.backgroundSecondary)
            } footer: {
                Text("Removes this server's SSH key and host info from the device. You'll need to add the public key back to `~/.ssh/authorized_keys` to reconnect.")
                    .font(.caption)
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("System")
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
