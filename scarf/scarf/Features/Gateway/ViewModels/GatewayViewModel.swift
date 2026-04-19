import Foundation

struct GatewayInfo {
    let pid: Int?
    let state: String
    let exitReason: String?
    let startTime: String?
    let updatedAt: String?
    let platforms: [PlatformInfo]
    let isLoaded: Bool
    let isStale: Bool
}

struct PlatformInfo: Identifiable {
    var id: String { name }
    let name: String
    let state: String
    let updatedAt: String?

    var isConnected: Bool { state == "connected" }

    var icon: String { KnownPlatforms.icon(for: name) }
}

struct PairedUser: Identifiable {
    var id: String { platform + userId }
    let platform: String
    let userId: String
    let name: String
}

struct PendingPairing: Identifiable {
    var id: String { platform + code }
    let platform: String
    let code: String
}

@Observable
final class GatewayViewModel {
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    var gateway = GatewayInfo(pid: nil, state: "unknown", exitReason: nil, startTime: nil, updatedAt: nil, platforms: [], isLoaded: false, isStale: false)
    var approvedUsers: [PairedUser] = []
    var pendingPairings: [PendingPairing] = []
    var isLoading = false
    var actionMessage: String?

    func load() {
        isLoading = true
        let ctx = context
        Task.detached { [weak self] in
            // Two sync transport calls + two CLI invocations — substantial
            // remote latency. Detach the whole load and commit at the end.
            let status = Self.fetchGatewayStatus(context: ctx)
            let pairing = Self.fetchPairing(context: ctx)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.gateway = status
                self.approvedUsers = pairing.approved
                self.pendingPairings = pairing.pending
                self.isLoading = false
            }
        }
    }

    /// Static form of the gateway-status walk so the detached load can call
    /// it without bouncing back to MainActor.
    nonisolated private static func fetchGatewayStatus(context: ServerContext) -> GatewayInfo {
        let stateJSON = context.readData(context.paths.gatewayStateJSON)
        var pid: Int?
        var state = "unknown"
        var exitReason: String?
        var startTime: String?
        var updatedAt: String?
        var platforms: [PlatformInfo] = []

        if let data = stateJSON,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pid = json["pid"] as? Int
            state = json["gateway_state"] as? String ?? "unknown"
            exitReason = json["exit_reason"] as? String
            startTime = json["start_time"] as? String
            updatedAt = json["updated_at"] as? String
            if let plats = json["platforms"] as? [String: Any] {
                platforms = plats.compactMap { key, value in
                    guard let info = value as? [String: Any] else { return nil }
                    return PlatformInfo(
                        name: key,
                        state: info["state"] as? String ?? "unknown",
                        updatedAt: info["updated_at"] as? String
                    )
                }.sorted { $0.name < $1.name }
            }
        }

        let statusOutput = context.runHermes(["gateway", "status"]).output
        let isLoaded = statusOutput.contains("service is loaded")
        let isStale = statusOutput.contains("stale")

        return GatewayInfo(
            pid: pid, state: state, exitReason: exitReason,
            startTime: startTime, updatedAt: updatedAt,
            platforms: platforms, isLoaded: isLoaded, isStale: isStale
        )
    }

    nonisolated private static func fetchPairing(context: ServerContext) -> (approved: [PairedUser], pending: [PendingPairing]) {
        let output = context.runHermes(["pairing", "list"]).output
        var approved: [PairedUser] = []
        var pending: [PendingPairing] = []

        var inApproved = false
        var inPending = false

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("Approved Users") { inApproved = true; inPending = false; continue }
            if trimmed.contains("Pending") { inPending = true; inApproved = false; continue }
            if trimmed.isEmpty || trimmed.hasPrefix("Platform") || trimmed.hasPrefix("--------") { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if inApproved && parts.count >= 3 {
                let platform = String(parts[0])
                let userId = String(parts[1])
                let name = parts[2...].joined(separator: " ")
                approved.append(PairedUser(platform: platform, userId: userId, name: name))
            } else if inPending && parts.count >= 2 {
                let platform = String(parts[0])
                let code = String(parts[1])
                pending.append(PendingPairing(platform: platform, code: code))
            }
        }
        return (approved, pending)
    }

    func startGateway() {
        runHermes(["gateway", "start"])
        actionMessage = "Gateway start requested"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.load()
            self?.actionMessage = nil
        }
    }

    func stopGateway() {
        runHermes(["gateway", "stop"])
        actionMessage = "Gateway stop requested"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.load()
            self?.actionMessage = nil
        }
    }

    func restartGateway() {
        runHermes(["gateway", "restart"])
        actionMessage = "Gateway restart requested"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.load()
            self?.actionMessage = nil
        }
    }

    func approvePairing(platform: String, code: String) {
        runHermes(["pairing", "approve", platform, code])
        load()
    }

    func revokeUser(_ user: PairedUser) {
        runHermes(["pairing", "revoke", user.platform, user.userId])
        approvedUsers.removeAll { $0.id == user.id }
    }

    // MARK: - Private
    // (loadGatewayStatus / loadPairing were moved to static helpers above
    // so the detached load() can run them without touching MainActor state.)

    @discardableResult
    private func runHermes(_ arguments: [String]) -> (output: String, exitCode: Int32) {
        context.runHermes(arguments)
    }
}
