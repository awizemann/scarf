import Foundation
import ScarfCore

@Observable
final class MCPServersViewModel {
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var servers: [HermesMCPServer] = []
    var selectedServerName: String?
    var searchText = ""
    var isLoading = false
    var statusMessage: String?
    var showPresetPicker = false
    var showAddCustom = false
    var showRestartBanner = false
    var testResults: [String: MCPTestResult] = [:]
    var testingNames: Set<String> = []
    var activeError: String?
    var editingServer: HermesMCPServer?
    /// v0.15 — `hermes mcp catalog` discovery sheet. `showCatalog` drives the
    /// sheet; `catalogText` holds the raw CLI text output (no `--json`);
    /// `isLoadingCatalog` gates a spinner while the CLI runs.
    var showCatalog = false
    var catalogText = ""
    var isLoadingCatalog = false

    var filteredServers: [HermesMCPServer] {
        guard !searchText.isEmpty else { return servers }
        let query = searchText.lowercased()
        return servers.filter { server in
            server.name.lowercased().contains(query) ||
            server.summary.lowercased().contains(query)
        }
    }

    var stdioServers: [HermesMCPServer] {
        filteredServers.filter { $0.transport == .stdio }
    }

    var httpServers: [HermesMCPServer] {
        filteredServers.filter { $0.transport == .http }
    }

    var sseServers: [HermesMCPServer] {
        filteredServers.filter { $0.transport == .sse }
    }

    var selectedServer: HermesMCPServer? {
        guard let name = selectedServerName else { return nil }
        return servers.first(where: { $0.name == name })
    }

    /// `hasLoaded` lets a plain section re-entry skip the config.yaml +
    /// mcp-tokens read (the VM is cached in `AppCoordinator` and persists
    /// across switches); Reload and post-mutation reloads pass `force: true`
    /// (t-aud24).
    @ObservationIgnored private var hasLoaded = false

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        let svc = fileService
        Task.detached { [weak self] in
            // loadMCPServers reads config.yaml + lists mcp-tokens — both
            // are sync transport calls that block on remote ssh round-trips.
            let result = svc.loadMCPServers()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.servers = result
                self.isLoading = false
                if let name = self.selectedServerName, !result.contains(where: { $0.name == name }) {
                    self.selectedServerName = nil
                }
            }
        }
    }

    func selectServer(name: String?) {
        selectedServerName = name
    }

    func beginEdit() {
        editingServer = selectedServer
    }

    func finishEdit(reload: Bool) {
        editingServer = nil
        if reload {
            // `force: true` is required, not cosmetic: `hasLoaded` is
            // already true by the time anyone can open the editor, so a
            // plain `load()` returns immediately and the list keeps
            // rendering the pre-edit values until the next section switch.
            load(force: true)
            showRestartBanner = true
        }
    }

    func deleteServer(name: String) {
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result = fileService.removeMCPServer(name: name)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.exitCode == 0 {
                    self.flashStatus("Removed \(name)")
                    if self.selectedServerName == name {
                        self.selectedServerName = nil
                    }
                    self.testResults.removeValue(forKey: name)
                    self.load(force: true)
                    self.showRestartBanner = true
                } else {
                    self.activeError = "Remove failed: \(result.output)"
                }
            }
        }
    }

    func toggleEnabled(name: String) {
        guard let server = servers.first(where: { $0.name == name }) else { return }
        let newValue = !server.enabled
        let fileService = self.fileService
        Task.detached { [weak self] in
            let ok = fileService.toggleMCPServerEnabled(name: name, enabled: newValue)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.flashStatus(newValue ? "Enabled \(name)" : "Disabled \(name)")
                    self.load(force: true)
                    self.showRestartBanner = true
                } else {
                    self.activeError = "Could not update \(name)"
                }
            }
        }
    }

    func testServer(name: String) {
        guard !testingNames.contains(name) else { return }
        testingNames.insert(name)
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result = await fileService.testMCPServer(name: name)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.testingNames.remove(name)
                self.testResults[name] = result
            }
        }
    }

    func testAll() {
        let targets = servers.map(\.name)
        let fileService = self.fileService
        Task.detached { [weak self] in
            for name in targets {
                let result = await fileService.testMCPServer(name: name)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.testResults[name] = result
                }
            }
        }
    }

    func addFromPreset(preset: MCPServerPreset, name: String, pathArg: String?, envValues: [String: String]) {
        let fileService = self.fileService
        let allArgs: [String] = {
            var base = preset.args
            if let pathArg, !pathArg.isEmpty { base.append(pathArg) }
            return base
        }()
        Task.detached { [weak self] in
            let addResult: (exitCode: Int32, output: String)
            switch preset.transport {
            case .stdio:
                // Env goes in at add time too: many stdio servers refuse to
                // start (and so fail the CLI's discovery probe) without
                // their token, and a failed probe is what used to leave the
                // entry disabled.
                addResult = fileService.addMCPServerStdio(
                    name: name,
                    command: preset.command ?? "",
                    args: allArgs,
                    env: envValues
                )
            case .http:
                addResult = fileService.addMCPServerHTTP(
                    name: name,
                    url: preset.url ?? "",
                    auth: preset.auth
                )
            case .sse:
                // No SSE-transport presets ship today; the preset picker
                // only surfaces stdio/http servers. Treat as a no-op
                // failure if a preset somehow declares .sse.
                addResult = (exitCode: 1, output: "SSE-transport presets are not supported.")
            }
            guard addResult.exitCode == 0 else {
                await MainActor.run { [weak self] in
                    self?.activeError = "Add failed: \(addResult.output)"
                }
                return
            }
            // Re-assert env on the saved entry: the stdio path already
            // passed it via `--env`, but the HTTP path has no such flag.
            if !envValues.isEmpty {
                _ = fileService.setMCPServerEnv(name: name, env: envValues)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.flashStatus("Added \(name)")
                self.load(force: true)
                self.selectedServerName = name
                self.showRestartBanner = true
                self.showPresetPicker = false
            }
        }
    }

    /// Writes a catalog entry's tool defaults into the freshly-added
    /// server, mirroring `mcp_catalog.py` at install time.
    ///
    /// Both halves of the manifest matter and they are mutually exclusive:
    /// `tools.default_excluded` becomes `tools.exclude`, and
    /// `tools.default_enabled` becomes `tools.include` — an allow-list, so
    /// everything the server adds later stays off until the user opts in.
    /// Scarf carried only the exclude half, so entries that ship an
    /// allow-list (n8n, databricks, comfy, kiwi) installed with **every**
    /// tool live, which is the opposite of what the catalog asked for.
    nonisolated private static func applyCatalogToolDefaults(
        fileService: HermesFileService,
        name: String,
        defaultEnabledTools: [String],
        defaultExcludedTools: [String]
    ) {
        guard !defaultEnabledTools.isEmpty || !defaultExcludedTools.isEmpty else { return }
        _ = fileService.updateMCPToolFilters(
            name: name,
            include: defaultEnabledTools,
            exclude: defaultExcludedTools,
            resources: true,
            prompts: true
        )
    }

    func addCustom(
        name: String,
        transport: MCPTransport,
        command: String,
        args: [String],
        url: String,
        auth: String?,
        apiKey: String = "",
        defaultEnabledTools: [String] = [],
        defaultExcludedTools: [String] = []
    ) {
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result: (exitCode: Int32, output: String)
            switch transport {
            case .stdio:
                result = fileService.addMCPServerStdio(name: name, command: command, args: args)
            case .http:
                result = fileService.addMCPServerHTTP(name: name, url: url, auth: auth, apiKey: apiKey)
            case .sse:
                // Routed through addCustomSSE; this branch is unreachable from
                // the add-server form (which dispatches per-transport in submit())
                // but kept so the switch is exhaustive without `@unknown default`.
                result = (exitCode: 1, output: "SSE servers must be added via addCustomSSE.")
            }
            if result.exitCode == 0 {
                Self.applyCatalogToolDefaults(
                    fileService: fileService,
                    name: name,
                    defaultEnabledTools: defaultEnabledTools,
                    defaultExcludedTools: defaultExcludedTools
                )
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.exitCode == 0 {
                    self.flashStatus("Added \(name)")
                    self.load(force: true)
                    self.selectedServerName = name
                    self.showRestartBanner = true
                    self.showAddCustom = false
                } else {
                    self.activeError = "Add failed: \(result.output)"
                }
            }
        }
    }

    /// v0.13+ SSE-transport server creation. Caller is responsible for
    /// capability-gating; the form filters `.sse` out of `availableTransports`
    /// when `hasMCPSSETransport` is false, so this method is unreachable
    /// from the UI on pre-v0.13 hosts.
    func addCustomSSE(
        name: String,
        url: String,
        sseReadTimeout: Int?,
        auth: String? = nil,
        apiKey: String = "",
        defaultEnabledTools: [String] = [],
        defaultExcludedTools: [String] = []
    ) {
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result = fileService.addMCPServerSSE(
                name: name, url: url, sseReadTimeout: sseReadTimeout, auth: auth, apiKey: apiKey
            )
            if result.exitCode == 0 {
                Self.applyCatalogToolDefaults(
                    fileService: fileService,
                    name: name,
                    defaultEnabledTools: defaultEnabledTools,
                    defaultExcludedTools: defaultExcludedTools
                )
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.exitCode == 0 {
                    self.flashStatus("Added \(name)")
                    self.load(force: true)
                    self.selectedServerName = name
                    self.showRestartBanner = true
                    self.showAddCustom = false
                } else {
                    self.activeError = "Add failed: \(result.output)"
                }
            }
        }
    }

    /// v0.15 — runs `hermes mcp catalog` (text output, no `--json`) off the
    /// MainActor and shows the raw result in a read-only sheet. Caller is
    /// responsible for capability-gating (`HermesCapabilities.hasMCPCatalog`);
    /// pre-v0.15 hosts reject the subcommand at argparse time.
    func browseCatalog() {
        showCatalog = true
        isLoadingCatalog = true
        catalogText = ""
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result = fileService.runHermesCLI(args: ["mcp", "catalog"], timeout: 45)
            let text = result.output.isEmpty
                ? "No catalog output. Requires Hermes v0.15+ — check that `hermes mcp catalog` runs on this host."
                : result.output
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.catalogText = text
                self.isLoadingCatalog = false
            }
        }
    }

    func restartGateway() {
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result = fileService.restartGateway()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.exitCode == 0 {
                    self.flashStatus("Gateway restarted")
                    self.showRestartBanner = false
                } else {
                    self.activeError = "Restart failed: \(result.output)"
                }
            }
        }
    }

    func flashStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if self.statusMessage == message {
                    self.statusMessage = nil
                }
            }
        }
    }
}
