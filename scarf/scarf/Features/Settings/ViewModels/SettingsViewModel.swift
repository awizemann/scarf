import Foundation

@Observable
final class SettingsViewModel {
    private let fileService = HermesFileService()

    var config = HermesConfig.empty
    var gatewayState: GatewayState?
    var hermesRunning = false
    var rawConfigYAML = ""

    func load() {
        config = fileService.loadConfig()
        gatewayState = fileService.loadGatewayState()
        hermesRunning = fileService.isHermesRunning()
        rawConfigYAML = (try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8)) ?? ""
    }
}
