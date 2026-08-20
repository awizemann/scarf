import SwiftUI
import ScarfCore
import os

@main
struct ScarfApp: App {
    /// User-editable list of remote servers. Loaded from
    /// `~/Library/Application Support/scarf/servers.json` at launch.
    @State private var registry = ServerRegistry()
    /// One live status per registered server (Local + every remote). Polled
    /// in the background to keep the menu bar fresh without making it own
    /// per-window state.
    @State private var liveRegistry: ServerLiveStatusRegistry
    @State private var updater = UpdaterService()

    init() {
        // ScarfMon — open-source perf instrumentation. Reads the
        // user-toggled mode from UserDefaults and installs the
        // matching backend set. Default `.signpostOnly` keeps
        // Instruments-attached profiling working without users
        // having to opt in. Settings → Diagnostics → Performance
        // flips this between off / signpost-only / full.
        ScarfMonBoot.configure(mode: ScarfMonBoot.currentMode())

        // Point ScarfCore's analytics seam at this target's facade. The
        // package itself links no analytics SDK (it's shared verbatim with
        // iOS, which installs nothing and stays a no-op); this is the single
        // place the two halves are joined. Must run before anything that can
        // transition the connection gate or a status view model, i.e. before
        // the registries below are built.
        Analytics.installCoreBridge()

        let registry = ServerRegistry()
        let live = ServerLiveStatusRegistry(registry: registry)
        // Re-fan-out statuses whenever the user adds/removes/renames a
        // server in the picker. Without this, new servers wouldn't appear
        // in the menu bar until the next full app launch.
        registry.onEntriesChanged = { [weak live] in live?.rebuild() }
        _registry = State(initialValue: registry)
        _liveRegistry = State(initialValue: live)

        // Prune snapshot cache dirs whose server UUIDs aren't in the registry
        // anymore — handles the case where a server was removed while Scarf
        // wasn't running. Cheap: just an `ls` of the snapshots root.
        registry.sweepOrphanCaches()

        // v2.7 cache cleanup: the remote-DB pipeline switched from
        // "snapshot the whole state.db locally" to "stream queries
        // over SSH per call" (issue #74). Old snapshot files for an
        // active 5GB-DB user could be 5GB+ on disk, with no live
        // codepath that would ever clean them up. Wipe the snapshots
        // root once at first launch on the new build. Subsequent
        // launches no-op via the UserDefaults flag.
        if !UserDefaults.standard.bool(forKey: "scarf.v27.snapshotCacheCleaned") {
            try? FileManager.default.removeItem(atPath: SSHTransport.snapshotRootPath())
            UserDefaults.standard.set(true, forKey: "scarf.v27.snapshotCacheCleaned")
        }

        // Wire ScarfCore's SSHTransport to the Mac-target login-shell env
        // probe. Without this, `ssh`/`scp` subprocesses spawned from Scarf
        // can't reach 1Password / Secretive / `.zshrc`-exported ssh-agent
        // sockets and auth fails with "Permission denied" (exit 255) even
        // though terminal ssh works fine. iOS leaves this unset — Citadel
        // owns the agent there.
        SSHTransport.environmentEnricher = { HermesFileService.enrichedEnvironment() }

        // Same enrichment for LocalTransport. Without this, GUI-launched
        // Scarf hands every local subprocess (hermes acp, hermes kanban
        // dispatch, sqlite3, etc.) macOS's stripped launch-services PATH
        // — `/usr/bin:/bin:/usr/sbin:/sbin` — and child invocations
        // (notably the kanban dispatcher's `hermes` worker spawn) fail
        // with `executable not found on PATH`, recording an
        // `outcome=spawn_failed` run on the task. The login-shell probe
        // populates PATH with `~/.local/bin`, Homebrew, etc., matching
        // what a Terminal session sees.
        LocalTransport.environmentEnricher = { HermesFileService.enrichedEnvironment() }

        // Warm up the login-shell env probe off-main at launch. Without
        // this, the first MainActor caller (chat preflight, OAuth flow,
        // signal-cli detect, etc.) blocks for 5-8 seconds while
        // `zsh -l -i` runs. Doing it eagerly on a detached task means the
        // static let is already populated by the time any UI needs it.
        Task.detached(priority: .utility) {
            _ = HermesFileService.enrichedEnvironment()
        }

        // Bootstrap built-in skills shipped inside the app bundle into
        // `~/.hermes/skills/scarf/`. Today this is just
        // `scarf-template-author`, which the "New Project from Scratch"
        // wizard hands off to. The service is idempotent + version-gated;
        // failures log and don't block launch — worst case is the wizard
        // still works but the agent doesn't have the skill loaded for
        // that session.
        Task.detached(priority: .utility) {
            do {
                try SkillBootstrapService(context: .local).ensureBundledSkillsInstalled()
            } catch {
                Logger(subsystem: "com.scarf", category: "scarfApp")
                    .warning("skill bootstrap failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Bootstrap global Scarf slash commands shipped inside the app
        // bundle into `~/.hermes/scarf/slash-commands/`. These are the
        // `/scarf-*` family that surfaces in EVERY chat (pre-session,
        // global, project-scoped) so the user can drive Scarf-specific
        // workflows without having to author per-project commands first.
        // Same idempotent + version-gated pattern as
        // `SkillBootstrapService`; failures log and don't block launch.
        Task.detached(priority: .utility) {
            do {
                try SlashCommandBootstrapService(context: .local).ensureBundledCommandsInstalled()
            } catch {
                Logger(subsystem: "com.scarf", category: "scarfApp")
                    .warning("slash command bootstrap failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Reconcile every registered project's secrets-env block in
        // ~/.hermes/.env. Catches users upgrading from a pre-mirror
        // Scarf version (existing projects' Keychain values weren't
        // mirrored before) and any drift between the Keychain state
        // and the env file. Idempotent — projects whose blocks are
        // already current produce no write.
        Task.detached(priority: .utility) {
            do {
                try KeychainEnvMirror(context: .local).reconcileAll()
            } catch {
                Logger(subsystem: "com.scarf", category: "scarfApp")
                    .warning("env-mirror reconcile failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Test-mode launch-URL handoff. When XCUITest passes
        // `--scarf-test-install-url <https-url>`, route the URL
        // through `TemplateURLRouter` so `ProjectsView`'s onAppear
        // hook dispatches it as if the user had clicked a
        // `scarf://install` deep link. Bypasses the SwiftUI/AppKit
        // Menu accessibility-bridging issues that otherwise block
        // XCUITest from driving the toolbar menu's "Browse Catalog…"
        // / "Install from URL…" items reliably. Production launches
        // (no flag) untouched.
        if TestModeFlags.shared.isTestMode,
           let idx = CommandLine.arguments.firstIndex(of: "--scarf-test-install-url"),
           idx + 1 < CommandLine.arguments.count,
           let url = URL(string: "scarf://install?url=" + CommandLine.arguments[idx + 1]) {
            TemplateURLRouter.shared.handle(url)
        }
    }

    var body: some Scene {
        // Multi-window: each window is bound to one `ServerID`. Opening a
        // second server via `openWindow(value:)` creates a second window
        // with its own coordinator + services; they're independent and can
        // run side-by-side. SwiftUI handles window-state restoration
        // automatically — quit + relaunch reopens the same windows with the
        // same server bindings.
        WindowGroup("Hermes", for: ServerID.self) { $serverID in
            // `nil` means the user removed this server since the window was
            // last open. Show a dedicated "server removed" view rather than
            // silently falling back to local — falling back would mislead
            // the user into thinking they're looking at the right server.
            if let ctx = registry.context(for: serverID) {
                // ProfileScopedRoot owns this window's "viewing profile" (#126)
                // and injects the profile-scoped `\.serverContext`. The
                // registry/liveRegistry/updater environments and the
                // onAppear/onOpenURL handlers stay OUT here, above the profile
                // rebuild boundary, so they don't re-fire on a profile switch.
                ProfileScopedRoot(baseContext: ctx)
                    .environment(registry)
                    .environment(liveRegistry)
                    .environment(updater)
                    // Sync the live-status set whenever a window appears —
                    // covers the case where the user added a server in
                    // another window since this one last opened.
                    .onAppear { liveRegistry.rebuild() }
                    // scarf://install?url=… deep-link handler. Stages the
                    // URL on the process-wide router; ProjectsView picks it
                    // up and presents the install sheet. Activating the
                    // app here ensures a cold launch from a browser click
                    // surfaces the sheet without the user having to click
                    // into Scarf first.
                    .onOpenURL { url in
                        TemplateURLRouter.shared.handle(url)
                        NSApplication.shared.activate()
                    }
            } else {
                // MissingServerView is a dead-end "server was removed" pane
                // with no ProjectsView — so no observer of the router's
                // pendingInstallURL exists in this window. Routing a
                // scarf://install URL here would silently drop it. Leave
                // onOpenURL off this branch; ContextBoundRoot windows in
                // the same app instance will still handle it.
                MissingServerView(removedServerID: serverID)
                    .environment(registry)
                    .environment(updater)
            }
        } defaultValue: {
            // Honour the user's "open on launch" choice from the Manage
            // Servers popover. Falls back to Local when no entry is flagged
            // (the default behaviour for fresh installs) or when the
            // flagged entry was removed while the app was closed.
            registry.defaultServerID
        }
        .defaultSize(width: 1100, height: 700)
        // Without an explicit resizability, `WindowGroup` defaults to
        // `.automatic` which on macOS evaluates to `.contentSize` —
        // meaning the window is BOUND to its content's ideal size
        // rather than bounded-below by it. Any section whose content's
        // intrinsic height changes (Chat's message list, the v2.3
        // per-project Sessions tab, Insights charts) would resize the
        // window on every section switch, snap back against user
        // resize, and sometimes push the whole window past the
        // screen. `.contentMinSize` turns the content's ideal height
        // into a minimum floor: user resize works freely, the window
        // stays put across section switches, and it still can't shrink
        // smaller than a section's minimum render.
        .windowResizability(.contentMinSize)
        .commands {
            // Standard ⌘, Settings. Scarf has no separate `Settings`
            // scene — settings is an in-window sidebar section — so route
            // the command to the focused window's coordinator via
            // `@FocusedValue`. (t-aud06)
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
            // Standard Help menu → docs (was absent). (t-aud18)
            CommandGroup(replacing: .help) {
                if let url = URL(string: "https://hermes-agent.nousresearch.com/docs") {
                    Link("Scarf & Hermes Documentation", destination: url)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            // File → Open Server submenu: one entry per registered server
            // (including Local). Each opens or focuses a window bound to
            // that server.
            CommandGroup(after: .newItem) {
                OpenServerCommands()
                    .environment(registry)
            }
        }

        MenuBarExtra(
            "Scarf",
            systemImage: liveRegistry.anyRunning ? "hare.fill" : "hare"
        ) {
            MenuBarMenu(liveRegistry: liveRegistry, updater: updater)
        }
    }
}

/// Renders the `File → Open Server →` submenu plus per-server number
/// shortcuts (⌘1…⌘9). Uses `@Environment(\.openWindow)` so each menu item
/// opens (or focuses) a window keyed to that server's `ServerID`. Extracted
/// into its own View so the `@Environment` access happens inside a View
/// context — `.commands` closures can't access it directly.
private struct OpenServerCommands: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Open Server") {
            // Local is always slot 1 (⌘1).
            Button {
                openWindow(value: ServerContext.local.id)
            } label: {
                Label("Local", systemImage: "laptopcomputer")
            }
            .keyboardShortcut("1", modifiers: .command)

            if !registry.entries.isEmpty {
                Divider()
                // First 8 remote entries get ⌘2…⌘9. Beyond 9 servers,
                // entries lose their shortcut but remain clickable.
                ForEach(Array(registry.entries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                    Button {
                        openWindow(value: entry.id)
                    } label: {
                        Label(entry.displayName, systemImage: "server.rack")
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: .command)
                }
                if registry.entries.count > 8 {
                    ForEach(registry.entries.dropFirst(8)) { entry in
                        Button {
                            openWindow(value: entry.id)
                        } label: {
                            Label(entry.displayName, systemImage: "server.rack")
                        }
                    }
                }
            }
            Divider()
            // Quick "open the picker" shortcut. Uses ⌘⇧S because ⌘⇧O is
            // commonly bound to "Open in new tab" by browser/IDE muscle memory
            // and we want to feel additive, not conflicting.
            Button {
                openWindow(value: ServerContext.local.id)
            } label: {
                Label("Manage Servers…", systemImage: "server.rack")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Carries the focused window's `AppCoordinator` up to the app-level
/// `.commands` block so menu commands (⌘, Settings) can drive the
/// in-window sidebar navigation of whichever window is frontmost. Scarf
/// has no separate `Settings` scene — settings is a sidebar section — so
/// the standard ⌘, must route through here. (t-aud06)
private struct AppCoordinatorFocusedValueKey: FocusedValueKey {
    typealias Value = AppCoordinator
}

extension FocusedValues {
    var appCoordinator: AppCoordinator? {
        get { self[AppCoordinatorFocusedValueKey.self] }
        set { self[AppCoordinatorFocusedValueKey.self] = newValue }
    }
}

/// App-menu "Settings…" command (⌘,) that opens the in-window Settings
/// sidebar section of the focused window. Disabled when no Scarf window
/// is focused (e.g. only a MissingServerView window is open). (t-aud06)
private struct OpenSettingsCommand: View {
    @FocusedValue(\.appCoordinator) private var coordinator

    var body: some View {
        Button("Settings…") {
            coordinator?.selectedSection = .settings
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(coordinator == nil)
    }
}

/// Owns this window's "viewing profile" selection (#126) and re-points the
/// bound `ServerContext` at the selected profile's `HERMES_HOME` via
/// `ServerContext.scoped(toProfile:)`. Sits ABOVE `ContextBoundRoot` so that
/// switching the viewing profile changes the `.id` below, which tears down
/// and rebuilds every per-window service (chat, file watcher, capabilities,
/// Sessions) against the new home — the client-side, no-relaunch analogue of
/// "Switch & Relaunch", and the Mac counterpart to iOS Design B (#120).
///
/// The `WindowProfileScope` is published into the environment so the Profiles
/// UI can change the selection. For local windows `scoped(toProfile:)` is a
/// no-op, so this wrapper is transparent there.
private struct ProfileScopedRoot: View {
    let baseContext: ServerContext
    @State private var scope: WindowProfileScope

    init(baseContext: ServerContext) {
        self.baseContext = baseContext
        _scope = State(initialValue: WindowProfileScope(serverID: baseContext.id))
    }

    var body: some View {
        let ctx = baseContext.scoped(toProfile: scope.selectedProfile)
        ContextBoundRoot(context: ctx)
            .environment(\.serverContext, ctx)
            .environment(scope)
            // A viewing-profile switch changes this id, reinitializing
            // ContextBoundRoot's @State services against the new HERMES_HOME.
            // Default profile (nil) maps to a stable sentinel so it has its
            // own identity distinct from every named profile.
            .id(scope.selectedProfile ?? HermesProfileScope.defaultProfileName)
    }
}

/// Wrapper View whose lifetime is scoped to one `ServerContext`. All
/// per-server `@State` — file watcher, coordinator, chat — lives here so
/// that the enclosing `.id(context.id)` modifier in `ScarfApp` cleanly
/// reinitializes everything when the user switches servers.
private struct ContextBoundRoot: View {
    let context: ServerContext

    @State private var coordinator: AppCoordinator
    @State private var fileWatcher: HermesFileWatcher
    @State private var chatViewModel: ChatViewModel
    /// Per-window snapshot of the target Hermes installation's capability
    /// flags. Drives sidebar visibility (Curator, Kanban only on v0.12+),
    /// settings rows (curator aux added on v0.12), and version banners.
    /// Refreshes once on init; explicit `refresh()` call rerun after a
    /// `hermes update`.
    @State private var capabilities: HermesCapabilitiesStore

    init(context: ServerContext) {
        self.context = context
        _coordinator = State(initialValue: AppCoordinator())
        _fileWatcher = State(initialValue: HermesFileWatcher(context: context))
        _chatViewModel = State(initialValue: ChatViewModel(context: context))
        _capabilities = State(initialValue: HermesCapabilitiesStore(context: context))
    }

    var body: some View {
        ContentView()
            .environment(coordinator)
            // Publish this window's coordinator to the app-level
            // `.commands` block so ⌘, (Settings) can drive the focused
            // window's sidebar navigation. (t-aud06)
            .focusedValue(\.appCoordinator, coordinator)
            .environment(fileWatcher)
            .environment(chatViewModel)
            .environment(capabilities)
            .hermesCapabilities(capabilities)
            // Per-window title shows which server this window is bound to.
            // Local: "Scarf — Local". Remote: "Scarf — Mardon Mac Mini".
            // The colored dot lives inside the toolbar switcher; the window
            // title gives macOS Mission Control / ⌘` cycling a meaningful
            // label so users can pick the right window without focusing it.
            .navigationTitle("Scarf — \(context.displayName)")
            // Persist this window's frame (size + position) across launches
            // with MANUAL UserDefaults + setFrame (NOT NSWindow's
            // frameAutosaveName — SwiftUI owns its own derived autosave name
            // and never re-applies it; see WindowFrameAutosave). The key is
            // per-server so each open server window remembers its own
            // geometry; new servers fall back to WindowGroup's `.defaultSize`
            // until first resize.
            .windowFrameAutosave("Scarf.Window.\(context.id)")
            .onAppear { fileWatcher.startWatching() }
            .onDisappear { fileWatcher.stopWatching() }
            // Re-detect Hermes capabilities when the app comes back to
            // the foreground. The user may have run `hermes update` in
            // a Terminal while Scarf was backgrounded — without this,
            // the slash menu, Kanban tab, and other version-gated UIs
            // stay on the old version's flag set until Scarf relaunches.
            // P1 of the projects-feature fix.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await capabilities.refresh() }
            }
    }
}

/// Per-server live state for the menu bar: is hermes running on this
/// server, is its gateway up, and the file service used to start/stop it.
/// One of these per registered server (plus local) so the menu bar can
/// fan out across multiple Hermes installations.
@Observable
@MainActor
final class ServerLiveStatus: Identifiable {
    let context: ServerContext
    private let fileService: HermesFileService
    private var pollTask: Task<Void, Never>?

    var hermesRunning = false
    var gatewayRunning = false

    /// When true (app not frontmost), the poll cadence is floored at 60s
    /// to cut background CPU + SSH round-trips against remotes (gh#102),
    /// while still keeping the menu-bar status reasonably fresh. Set by
    /// `ServerLiveStatusRegistry` on app activate/resign. (t-aud05)
    var lowPowerMode = false

    var id: ServerID { context.id }

    init(context: ServerContext) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            // Exponential backoff on consecutive failures. Healthy servers
            // poll every 10s. When a registered remote goes unreachable,
            // pgrep + gateway_state.json reads fail every tick — without
            // backoff that's a log warning + a 5s pgrep timeout every 10s
            // for as long as the remote stays down. Reset to 10s on the
            // first probe that fully succeeds.
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let ok = await self?.pollOnce() ?? false
                if Task.isCancelled { return }
                consecutiveFailures = ok ? 0 : consecutiveFailures + 1
                let base: UInt64
                switch consecutiveFailures {
                case 0:  base = 10
                case 1:  base = 30
                case 2:  base = 60
                case 3:  base = 120
                default: base = 300
                }
                // Floor the cadence at 60s while the app is backgrounded so
                // an idle/connected Scarf stops the 10s SSH-poll storm that
                // drove gh#102. Exponential backoff still applies on top.
                let delaySec = (self?.lowPowerMode ?? false) ? max(base, 60) : base
                try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Set by the registry on app activate/resign — floors the poll
    /// cadence at 60s while backgrounded (gh#102). (t-aud05)
    func setLowPowerMode(_ on: Bool) {
        lowPowerMode = on
    }

    /// Fire a single immediate probe — used on app-activate so the menu
    /// bar refreshes promptly instead of waiting out the background sleep.
    func pollNow() {
        refresh()
    }

    // MARK: - Hermes control
    //
    // The three public entry points are the menu bar's Start / Stop /
    // Restart buttons, and each emits exactly one `hermes_control_action`
    // carrying its own `action` — `restartHermes` routes through the
    // private `performStart`, not `startHermes`, so a restart reports one
    // `restart` event rather than a `restart` plus a stray `start`.

    /// Fire the gateway start and report whether the CLI accepted it.
    private nonisolated static func performStart(_ context: ServerContext) -> Bool {
        context.runHermes(["gateway", "start"]).exitCode == 0
    }

    func startHermes() {
        Task { [context] in
            let ok = await Task.detached { Self.performStart(context) }.value
            Analytics.record("hermes_control_action", props: [
                "action": "start",
                "source": "menu_bar",
                "outcome": ok ? "succeeded" : "failed",
            ])
        }
        // Refresh after a short delay to pick up the new state.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.refresh()
        }
    }

    func stopHermes() {
        Task { [fileService] in
            let ok = await Task.detached { fileService.stopHermes() }.value
            Analytics.record("hermes_control_action", props: [
                "action": "stop",
                "source": "menu_bar",
                "outcome": ok ? "succeeded" : "failed",
            ])
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.refresh()
        }
    }

    func restartHermes() {
        Task { [weak self, fileService, context] in
            let stopped = await Task.detached { fileService.stopHermes() }.value
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let started = await Task.detached { Self.performStart(context) }.value
            // A restart only succeeded if both halves did; a stop that
            // found nothing running still has to bring the gateway back.
            Analytics.record("hermes_control_action", props: [
                "action": "restart",
                "source": "menu_bar",
                "outcome": stopped && started ? "succeeded" : "failed",
            ])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.refresh()
        }
    }

    private func refresh() {
        Task { [weak self] in _ = await self?.pollOnce() }
    }

    /// Single probe used by both the polling loop (which needs the
    /// success/failure signal for backoff) and the fire-and-forget
    /// `refresh()` callers (start/stop/restart). Returns `true` only when
    /// both the pgrep call AND the gateway_state.json read returned a
    /// transport-level success — `.success(nil)` (file missing because
    /// hermes is stopped) still counts as a successful probe.
    private func pollOnce() async -> Bool {
        let svc = fileService
        struct ProbeResult: Sendable {
            let running: Bool
            let gatewayRunning: Bool
            let ok: Bool
        }
        let probe = await Task.detached { () -> ProbeResult in
            let pgrep = svc.hermesPIDResult()
            let gateway = svc.loadGatewayStateResult()
            let running: Bool
            switch pgrep {
            case .success(let pid): running = (pid != nil)
            case .failure: running = false
            }
            let gatewayRunning: Bool
            switch gateway {
            case .success(let state): gatewayRunning = state?.isRunning ?? false
            case .failure: gatewayRunning = false
            }
            let pgrepOK: Bool
            if case .failure = pgrep { pgrepOK = false } else { pgrepOK = true }
            let gatewayOK: Bool
            if case .failure = gateway { gatewayOK = false } else { gatewayOK = true }
            return ProbeResult(running: running, gatewayRunning: gatewayRunning, ok: pgrepOK && gatewayOK)
        }.value
        // Only republish when the value actually changed. `@Observable`
        // setters invalidate every dependent view on assignment, not on
        // change — without this guard the menu-bar chrome (and any
        // SwiftUI surface that observes `hermesRunning`) re-renders
        // every 10 s even when nothing moved. See gh#105: users with a
        // healthy steady-state server reported a visible flash every
        // poll cycle.
        if hermesRunning != probe.running {
            hermesRunning = probe.running
        }
        if gatewayRunning != probe.gatewayRunning {
            gatewayRunning = probe.gatewayRunning
        }
        return probe.ok
    }
}

/// App-scoped registry of `ServerLiveStatus` — one per known server. Adds /
/// removes in lockstep with `ServerRegistry`, so the menu bar accurately
/// reflects the current set of registered servers.
@Observable
@MainActor
final class ServerLiveStatusRegistry {
    private(set) var statuses: [ServerLiveStatus] = []
    private let registry: ServerRegistry
    /// True while the app is not frontmost — propagated to every status so
    /// polling drops to a low-power cadence (gh#102). (t-aud05)
    private var lowPowerMode = false
    init(registry: ServerRegistry) {
        self.registry = registry
        rebuild()
        observeAppLifecycle()
    }

    /// Slow down (not stop) polling when the app loses focus and restore
    /// it — with an immediate refresh — when it returns. The poll loop
    /// keeps running at a 60s+ cadence in the background so the menu-bar
    /// status stays reasonably fresh, while the idle 10s SSH-poll storm
    /// that drove gh#102 goes away. App-lifetime registry, so the observer
    /// blocks aren't tracked for removal (NotificationCenter retains them
    /// for the process lifetime). (t-aud05)
    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        // queue: .main → the block runs on the main thread, so
        // MainActor.assumeIsolated is safe and avoids a Task hop.
        // These two blocks are also the app's single, app-lifetime pair of
        // foreground/background signals, so the analytics lifecycle hangs off
        // them rather than off a per-window `.onReceive` (which would fire once
        // per open window). AppKit has no true "did enter background" — a
        // macOS app that loses focus keeps running — so `didResignActive` is
        // the closest analogue and is what starts swift-stats' session-gap
        // timer. Both calls are nonisolated and non-suspending.
        _ = nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Analytics.applicationDidEnterBackground()
            MainActor.assumeIsolated { self?.setLowPowerMode(true) }
        }
        _ = nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Analytics.applicationDidBecomeActive()
            MainActor.assumeIsolated { self?.setLowPowerMode(false) }
        }
        // gh#123: system sleep usually kills the TCP session behind each
        // remote's ControlMaster while the master lingers holding its
        // socket — every ssh after wake (chat connect, these pollers,
        // file reads) then hangs on the corpse for its full timeout until
        // something issues `-O exit`. Probe each registered remote on
        // wake and reset only the provably dead masters. Note: NSWorkspace
        // notifications post on NSWorkspace's own center, not `.default`.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverRemoteControlMastersAfterWake() }
        }
    }

    /// Snapshot the registered ssh servers on the MainActor, then probe
    /// their ControlMasters off-main (each probe is up to ~15s of
    /// subprocess I/O). Healthy masters are left alone — only one whose
    /// TCP session died during sleep gets `-O exit`.
    private func recoverRemoteControlMastersAfterWake() {
        let remotes: [(ServerID, SSHConfig, String)] = registry.entries.compactMap { entry in
            guard case .ssh(let config) = entry.kind else { return nil }
            return (entry.id, config, entry.displayName)
        }
        guard !remotes.isEmpty else { return }
        Task.detached(priority: .utility) {
            // Give the network stack a beat to re-associate after wake so
            // a healthy master isn't misread as dead mid-DHCP.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // One event pair per wake, never per host: a fleet of ten
            // remotes is still one reconnect the user experiences. The
            // 3s settle above is excluded from the duration.
            let start = Date()
            var probed = 0
            var alive = 0
            for (id, config, name) in remotes {
                let outcome = SSHTransport(contextID: id, config: config, displayName: name)
                    .recoverControlMasterIfDead()
                switch outcome {
                case .noMaster: break   // nothing was connected; not a reconnect
                case .alive: probed += 1; alive += 1
                case .recovered: probed += 1
                }
            }
            // Only hosts that actually had a master to check count as an
            // attempt — otherwise every wake with zero live connections
            // would report a reconnect that never happened.
            guard probed > 0 else { return }
            Analytics.record("reconnect_attempted", props: ["trigger": "wake"])
            if alive > 0 {
                Analytics.record("reconnect_succeeded", props: [
                    "trigger": "wake",
                    "duration_bucket": Analytics.durationBucket(since: start),
                ])
            }
        }
    }

    private func setLowPowerMode(_ on: Bool) {
        guard on != lowPowerMode else { return }
        lowPowerMode = on
        for s in statuses { s.setLowPowerMode(on) }
        // On returning to the foreground, refresh immediately so the menu
        // bar doesn't wait out the (possibly 60s+) background sleep.
        if !on { for s in statuses { s.pollNow() } }
    }

    /// Recompute the status list from the source registry. Re-uses any
    /// existing status object whose ID still matches so we don't lose
    /// in-flight polling state on a server add/rename.
    func rebuild() {
        var newStatuses: [ServerLiveStatus] = []
        let allContexts = registry.allContexts
        for ctx in allContexts {
            if let existing = statuses.first(where: { $0.id == ctx.id }) {
                newStatuses.append(existing)
            } else {
                let status = ServerLiveStatus(context: ctx)
                status.setLowPowerMode(lowPowerMode)
                status.startPolling()
                newStatuses.append(status)
            }
        }
        // Stop polling on statuses that were removed.
        for old in statuses where !newStatuses.contains(where: { $0.id == old.id }) {
            old.stopPolling()
        }
        statuses = newStatuses
    }

    /// True if any registered server reports hermes running. Drives the
    /// menu bar icon (filled vs. outline hare).
    var anyRunning: Bool { statuses.contains(where: { $0.hermesRunning }) }
}

struct MenuBarMenu: View {
    let liveRegistry: ServerLiveStatusRegistry
    let updater: UpdaterService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One section per server with its run state + start/stop/restart.
            // Iterating registered statuses keeps the menu in sync as the
            // user adds/removes servers in the picker.
            ForEach(liveRegistry.statuses) { status in
                serverSection(status)
                Divider()
            }
            Button("Open Scarf") {
                NSApplication.shared.activate()
            }
            Divider()
            Button("Check for Updates…") { updater.checkForUpdates() }
            Divider()
            Button("Quit Scarf") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private func serverSection(_ status: ServerLiveStatus) -> some View {
        Group {
            // Server name as a header, with the open-window action on click.
            Button {
                openWindow(value: status.context.id)
                NSApplication.shared.activate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: status.context.isRemote ? "server.rack" : "laptopcomputer")
                    Text(status.context.displayName).bold()
                }
            }
            Label(
                status.hermesRunning ? "Hermes Running" : "Hermes Stopped",
                systemImage: status.hermesRunning ? "circle.fill" : "circle"
            )
            Label(
                status.gatewayRunning ? "Messaging Gateway Running" : "Messaging Gateway Stopped",
                systemImage: status.gatewayRunning ? "circle.fill" : "circle"
            )
            Button("Start Hermes") { status.startHermes() }
                .disabled(status.hermesRunning)
            Button("Stop Hermes") { status.stopHermes() }
                .disabled(!status.hermesRunning)
            Button("Restart Hermes") { status.restartHermes() }
                .disabled(!status.hermesRunning)
        }
    }
}
