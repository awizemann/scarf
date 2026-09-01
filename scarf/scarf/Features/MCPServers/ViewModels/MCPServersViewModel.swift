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
            load()
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
                addResult = fileService.addMCPServerStdio(
                    name: name,
                    command: preset.command ?? "",
                    args: allArgs
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

    func addCustom(name: String, transport: MCPTransport, command: String, args: [String], url: String, auth: String?, defaultExcludedTools: [String] = []) {
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result: (exitCode: Int32, output: String)
            switch transport {
            case .stdio:
                result = fileService.addMCPServerStdio(name: name, command: command, args: args)
            case .http:
                result = fileService.addMCPServerHTTP(name: name, url: url, auth: auth)
            case .sse:
                // Routed through addCustomSSE; this branch is unreachable from
                // the add-server form (which dispatches per-transport in submit())
                // but kept so the switch is exhaustive without `@unknown default`.
                result = (exitCode: 1, output: "SSE servers must be added via addCustomSSE.")
            }
            if result.exitCode == 0 && !defaultExcludedTools.isEmpty {
                // Mirrors mcp_catalog.py's `_write_tools_exclude` at install
                // time: a catalog entry's `tools.default_excluded` becomes
                // this server's `tools.exclude`, everything else stays
                // enabled (resources/prompts untouched — default on).
                _ = fileService.updateMCPToolFilters(
                    name: name, include: [], exclude: defaultExcludedTools, resources: true, prompts: true
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
    func addCustomSSE(name: String, url: String, sseReadTimeout: Int?, defaultExcludedTools: [String] = []) {
        let fileService = self.fileService
        Task.detached { [weak self] in
            let result = fileService.addMCPServerSSE(name: name, url: url, sseReadTimeout: sseReadTimeout)
            if result.exitCode == 0 && !defaultExcludedTools.isEmpty {
                _ = fileService.updateMCPToolFilters(
                    name: name, include: [], exclude: defaultExcludedTools, resources: true, prompts: true
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
