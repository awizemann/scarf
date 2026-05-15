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

    /// Stable per-tab context UUID — used for the System tab's Curator
    /// row so its CuratorViewModel reuses the cached SSH connection
    /// keyed by this id rather than building a fresh one. Same pattern
    /// as `sharedContextID` on ChatView.
    static let systemTabContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A2"
    )!

    /// One coordinator per server-connected session. Cross-tab
    /// signalling (Dashboard row → Chat tab resume, Project Detail
    /// → in-project chat handoff, notification deep-link → Chat) flows
    /// through here.
    @State private var coordinator = ScarfGoCoordinator()

    /// Hermes version + capability flags for this remote. Drives the
    /// iOS version banner (v0.11 hosts get a yellow "update for new
    /// features" banner) and capability-gated affordances like ACP
    /// image attachments. Constructed once per server connection so
    /// the detection runs over the active SSH transport.
    @State private var capabilities: HermesCapabilitiesStore

    init(
        serverID: ServerID,
        config: IOSServerConfig,
        key: SSHKeyBundle,
        onSoftDisconnect: @escaping @MainActor () async -> Void,
        onForget: @escaping @MainActor () async -> Void
    ) {
        self.serverID = serverID
        self.config = config
        self.key = key
        self.onSoftDisconnect = onSoftDisconnect
        self.onForget = onForget
        let ctx = config.toServerContext(id: serverID)
        _capabilities = State(initialValue: HermesCapabilitiesStore(context: ctx))
    }

    /// SwiftUI's `.onChange(of: ScenePhase)` modifier on a non-active
    /// tab doesn't fire while the tab is unmounted — the coordinator
    /// is the single source of truth for scene-phase transitions
    /// across all tabs.
    @Environment(\.scenePhase) private var scenePhase

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
                ChatConversationsLanding(config: config, key: key, serverID: serverID)
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
        .environment(capabilities)
        .hermesCapabilities(capabilities)
        .onAppear {
            // Give the notification router a handle to this session's
            // coordinator so notification-taps can route across tabs.
            // Weak ref — coordinator owns its own lifetime, router
            // just observes.
            NotificationRouter.shared.coordinator = coordinator
        }
        // Funnel scene-phase transitions through the coordinator so
        // tab view-models (notably ChatController) can react even
        // when their tab isn't currently on-screen.
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.setScenePhase(newPhase)
        }
    }
}

/// Chat tab landing: selecting the tab browses existing conversations instead
/// of mounting ChatView immediately. That avoids creating ACP placeholder
/// sessions just because the user tapped the tab; a fresh ACP session is only
/// created after the user opens New Chat and sends the first prompt.
private struct ChatConversationsLanding: View {
    let config: IOSServerConfig
    let key: SSHKeyBundle
    @State private var vm: IOSDashboardViewModel

    init(config: IOSServerConfig, key: SSHKeyBundle, serverID: ServerID) {
        self.config = config
        self.key = key
        _vm = State(initialValue: IOSDashboardViewModel(context: config.toServerContext(id: serverID)))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ChatView(config: config, key: key)
                } label: {
                    Label("New chat", systemImage: "plus.bubble")
                        .font(.headline)
                        .foregroundStyle(.tint)
                }
            }

            Section("Conversations") {
                if vm.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let error = vm.lastError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn't load chats")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Button("Retry") { Task { await vm.refresh() } }
                    }
                    .padding(.vertical, 6)
                } else if vm.allSessions.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a new chat when you're ready. No ACP session is created until you send a message.")
                    )
                } else {
                    ForEach(vm.allSessions) { session in
                        NavigationLink {
                            ChatView(config: config, key: key, initialSessionID: session.id)
                        } label: {
                            chatRow(session)
                        }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await vm.refresh() }
        .task { await vm.load() }
    }

    private func chatRow(_ session: HermesSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayTitle)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if let preview = vm.sessionPreviews[session.id], !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let started = session.startedAt {
                    Text(started, style: .relative)
                }
                if session.messageCount > 0 {
                    Text("\(session.messageCount) msg")
                }
                if session.toolCallCount > 0 {
                    Text("\(session.toolCallCount) tools")
                }
                if let project = vm.projectName(for: session) {
                    Text(project)
                }
            }
            .font(.caption)
            .foregroundStyle(ScarfColor.foregroundFaint)
        }
        .padding(.vertical, 3)
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

    @Environment(\.hermesCapabilities) private var capabilitiesStore

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
                if capabilitiesStore?.capabilities.hasCurator ?? false {
                    NavigationLink {
                        CuratorView(context: config.toServerContext(id: ScarfGoTabRoot.systemTabContextID))
                    } label: {
                        Label("Curator", systemImage: "sparkles")
                    }
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                }
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

            // v2.6: read-only mobile views over CLI-driven Hermes
            // surfaces. Mac owns the create/edit paths; phones get a
            // monitoring window into what the remote agent is honoring.
            // None of these are capability-gated — the underlying
            // `hermes plugins/profile/webhook list` verbs exist on
            // both v0.11 and v0.12, so the read views work on either.
            Section("Inspect") {
                NavigationLink {
                    WebhooksView(config: config)
                } label: {
                    Label("Webhooks", systemImage: "arrow.up.right.square")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
                NavigationLink {
                    PluginsView(config: config)
                } label: {
                    Label("Plugins", systemImage: "app.badge.checkmark")
                }
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
                NavigationLink {
                    ProfilesView(config: config)
                } label: {
                    Label("Profiles", systemImage: "person.2.crop.square.stack")
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
