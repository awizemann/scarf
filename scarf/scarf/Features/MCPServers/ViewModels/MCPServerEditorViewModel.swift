import Foundation

@Observable
final class MCPServerEditorViewModel {
    struct KeyValueRow: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    let context: ServerContext
    private let fileService: HermesFileService
    let server: HermesMCPServer

    var envDraft: [KeyValueRow]
    var headersDraft: [KeyValueRow]
    var includeDraft: String
    var excludeDraft: String
    var resourcesEnabled: Bool
    var promptsEnabled: Bool
    var timeoutDraft: String
    var connectTimeoutDraft: String
    var showSecrets: Bool = false
    var isSaving: Bool = false
    var saveError: String?

    init(server: HermesMCPServer, context: ServerContext = .local) {
        self.server = server
        self.context = context
        self.fileService = HermesFileService(context: context)
        self.envDraft = server.env.keys.sorted().map { KeyValueRow(key: $0, value: server.env[$0] ?? "") }
        self.headersDraft = server.headers.keys.sorted().map { KeyValueRow(key: $0, value: server.headers[$0] ?? "") }
        self.includeDraft = server.toolsInclude.joined(separator: ", ")
        self.excludeDraft = server.toolsExclude.joined(separator: ", ")
        self.resourcesEnabled = server.resourcesEnabled
        self.promptsEnabled = server.promptsEnabled
        self.timeoutDraft = server.timeout.map { String($0) } ?? ""
        self.connectTimeoutDraft = server.connectTimeout.map { String($0) } ?? ""
    }

    func appendEnvRow() {
        envDraft.append(KeyValueRow(key: "", value: ""))
    }

    func removeEnvRow(id: UUID) {
        envDraft.removeAll { $0.id == id }
    }

    func appendHeaderRow() {
        headersDraft.append(KeyValueRow(key: "", value: ""))
    }

    func removeHeaderRow(id: UUID) {
        headersDraft.removeAll { $0.id == id }
    }

    func save(completion: @escaping (Bool) -> Void) {
        isSaving = true
        saveError = nil

        let envMap = Dictionary(uniqueKeysWithValues: envDraft
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) })
        let headerMap = Dictionary(uniqueKeysWithValues: headersDraft
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) })
        let include = includeDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let exclude = excludeDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let timeoutValue = Int(timeoutDraft.trimmingCharacters(in: .whitespaces))
        let connectValue = Int(connectTimeoutDraft.trimmingCharacters(in: .whitespaces))

        let service = fileService
        let transport = server.transport
        let name = server.name
        let resources = resourcesEnabled
        let prompts = promptsEnabled

        Task.detached {
            // Compute success as an immutable so the MainActor.run closure
            // captures a value, not a mutable var. Swift 6 rejects
            // var-captures across concurrent closures as data races.
            let success: Bool = {
                var ok = true
                switch transport {
                case .stdio:
                    if !service.setMCPServerEnv(name: name, env: envMap) { ok = false }
                case .http:
                    if !service.setMCPServerHeaders(name: name, headers: headerMap) { ok = false }
                }
                if !service.updateMCPToolFilters(
                    name: name,
                    include: include,
                    exclude: exclude,
                    resources: resources,
                    prompts: prompts
                ) { ok = false }
                if !service.setMCPServerTimeouts(name: name, timeout: timeoutValue, connectTimeout: connectValue) {
                    ok = false
                }
                return ok
            }()
            await MainActor.run {
                self.isSaving = false
                if !success {
                    self.saveError = "One or more fields could not be written. Check \(self.context.paths.configYAML)."
                }
                completion(success)
            }
        }
    }

    func clearOAuthToken(completion: @escaping (Bool) -> Void) {
        let service = fileService
        let name = server.name
        Task.detached {
            let ok = service.deleteMCPOAuthToken(name: name)
            await MainActor.run { completion(ok) }
        }
    }
}
