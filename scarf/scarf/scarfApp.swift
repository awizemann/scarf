import SwiftUI

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

        // Warm up the login-shell env probe off-main at launch. Without
        // this, the first MainActor caller (chat preflight, OAuth flow,
        // signal-cli detect, etc.) blocks for 5-8 seconds while
        // `zsh -l -i` runs. Doing it eagerly on a detached task means the
        // static let is already populated by the time any UI needs it.
        Task.detached(priority: .utility) {
            _ = HermesFileService.enrichedEnvironment()
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
                ContextBoundRoot(context: ctx)
                    .environment(registry)
                    .environment(\.serverContext, ctx)
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

/// Wrapper View whose lifetime is scoped to one `ServerContext`. All
/// per-server `@State` — file watcher, coordinator, chat — lives here so
/// that the enclosing `.id(context.id)` modifier in `ScarfApp` cleanly
/// reinitializes everything when the user switches servers.
private struct ContextBoundRoot: View {
    let context: ServerContext

    @State private var coordinator: AppCoordinator
    @State private var fileWatcher: HermesFileWatcher
    @State private var chatViewModel: ChatViewModel

    init(context: ServerContext) {
        self.context = context
        _coordinator = State(initialValue: AppCoordinator())
        _fileWatcher = State(initialValue: HermesFileWatcher(context: context))
        _chatViewModel = State(initialValue: ChatViewModel(context: context))
    }

    var body: some View {
        ContentView()
            .environment(coordinator)
            .environment(fileWatcher)
            .environment(chatViewModel)
            // Per-window title shows which server this window is bound to.
            // Local: "Scarf — Local". Remote: "Scarf — Mardon Mac Mini".
            // The colored dot lives inside the toolbar switcher; the window
            // title gives macOS Mission Control / ⌘` cycling a meaningful
            // label so users can pick the right window without focusing it.
            .navigationTitle("Scarf — \(context.displayName)")
            .onAppear { fileWatcher.startWatching() }
            .onDisappear { fileWatcher.stopWatching() }
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

    var id: ServerID { context.id }

    init(context: ServerContext) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    func startPolling() {
        stopPolling()
        // First refresh inline so the icon doesn't flash "stopped" for the
        // first 10s after launch.
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func startHermes() {
        Task.detached { [context] in
            _ = context.runHermes(["gateway", "start"])
        }
        // Refresh after a short delay to pick up the new state.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.refresh()
        }
    }

    func stopHermes() {
        Task.detached { [fileService] in _ = fileService.stopHermes() }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.refresh()
        }
    }

    func restartHermes() {
        Task.detached { [fileService] in
            _ = fileService.stopHermes()
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.startHermes()
        }
    }

    private func refresh() {
        let svc = fileService
        Task.detached { [weak self] in
            let running = svc.isHermesRunning()
            let gateway = svc.loadGatewayState()?.isRunning ?? false
            await MainActor.run { [weak self] in
                self?.hermesRunning = running
                self?.gatewayRunning = gateway
            }
        }
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

    init(registry: ServerRegistry) {
        self.registry = registry
        rebuild()
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
                status.gatewayRunning ? "Gateway Running" : "Gateway Stopped",
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
