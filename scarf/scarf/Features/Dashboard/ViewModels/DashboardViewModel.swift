import Foundation

@Observable
final class DashboardViewModel {
    private let dataService = HermesDataService()
    private let fileService = HermesFileService()

    var stats = HermesDataService.SessionStats(
        totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
        totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0
    )
    var recentSessions: [HermesSession] = []
    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var isLoading = true

    func load() async {
        isLoading = true
        let opened = await dataService.open()
        if opened {
            stats = await dataService.fetchStats()
            recentSessions = await dataService.fetchSessions(limit: 5)
            await dataService.close()
        }
        config = fileService.loadConfig()
        gatewayState = fileService.loadGatewayState()
        hermesRunning = fileService.isHermesRunning()
        isLoading = false
    }
}
