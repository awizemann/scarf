import Foundation

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

    var selectedServer: HermesMCPServer? {
        guard let name = selectedServerName else { return nil }
        return servers.first(where: { $0.name == name })
    }

    func load() {
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
        Task.detached {
            let result = fileService.removeMCPServer(name: name)
            await MainActor.run {
                if result.exitCode == 0 {
                    self.flashStatus("Removed \(name)")
                    if self.selectedServerName == name {
                        self.selectedServerName = nil
                    }
                    self.testResults.removeValue(forKey: name)
                    self.load()
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
        Task.detached {
            let ok = fileService.toggleMCPServerEnabled(name: name, enabled: newValue)
            await MainActor.run {
                if ok {
                    self.flashStatus(newValue ? "Enabled \(name)" : "Disabled \(name)")
                    self.load()
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
        Task.detached {
            let result = await fileService.testMCPServer(name: name)
            await MainActor.run {
                self.testingNames.remove(name)
                self.testResults[name] = result
            }
        }
    }

    func testAll() {
        let targets = servers.map(\.name)
        let fileService = self.fileService
        Task.detached {
            for name in targets {
                let result = await fileService.testMCPServer(name: name)
                await MainActor.run {
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
        Task.detached {
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
            }
            guard addResult.exitCode == 0 else {
                await MainActor.run {
                    self.activeError = "Add failed: \(addResult.output)"
                }
                return
            }
            if !envValues.isEmpty {
                _ = fileService.setMCPServerEnv(name: name, env: envValues)
            }
            await MainActor.run {
                self.flashStatus("Added \(name)")
                self.load()
                self.selectedServerName = name
                self.showRestartBanner = true
                self.showPresetPicker = false
            }
        }
    }

    func addCustom(name: String, transport: MCPTransport, command: String, args: [String], url: String, auth: String?) {
        let fileService = self.fileService
        Task.detached {
            let result: (exitCode: Int32, output: String)
            switch transport {
            case .stdio:
                result = fileService.addMCPServerStdio(name: name, command: command, args: args)
            case .http:
                result = fileService.addMCPServerHTTP(name: name, url: url, auth: auth)
            }
            await MainActor.run {
                if result.exitCode == 0 {
                    self.flashStatus("Added \(name)")
                    self.load()
                    self.selectedServerName = name
                    self.showRestartBanner = true
                    self.showAddCustom = false
                } else {
                    self.activeError = "Add failed: \(result.output)"
                }
            }
        }
    }

    func restartGateway() {
        let fileService = self.fileService
        Task.detached {
            let result = fileService.restartGateway()
            await MainActor.run {
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
