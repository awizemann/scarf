import Foundation

@Observable
final class DashboardViewModel {
    let context: ServerContext
    private let dataService: HermesDataService
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        self.fileService = HermesFileService(context: context)
    }


    var stats = HermesDataService.SessionStats.empty
    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]
    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var isLoading = true

    func load() async {
        isLoading = true
        // refresh() = close + reopen, forces a fresh remote snapshot. Cheap
        // on local (live DB reopen).
        let opened = await dataService.refresh()
        if opened {
            stats = await dataService.fetchStats()
            recentSessions = await dataService.fetchSessions(limit: 5)
            sessionPreviews = await dataService.fetchSessionPreviews(limit: 5)
            await dataService.close()
        }
        // The fileService methods are synchronous and route through the
        // transport. For remote contexts each call is a blocking ssh
        // round-trip — do them off the main thread to avoid spinning the
        // beach ball during the load.
        let svc = fileService
        let (cfg, gw, running) = await Task.detached {
            (svc.loadConfig(), svc.loadGatewayState(), svc.isHermesRunning())
        }.value
        config = cfg
        gatewayState = gw
        hermesRunning = running
        isLoading = false
    }
}
