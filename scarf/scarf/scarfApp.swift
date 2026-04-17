import SwiftUI

@main
struct ScarfApp: App {
    @State private var coordinator = AppCoordinator()
    @State private var fileWatcher = HermesFileWatcher()
    @State private var menuBarStatus = MenuBarStatus()
    @State private var chatViewModel = ChatViewModel()
    @State private var updater = UpdaterService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .environment(fileWatcher)
                .environment(chatViewModel)
                .environment(updater)
                .onAppear {
                    fileWatcher.startWatching()
                    menuBarStatus.startPolling()
                }
                .onDisappear {
                    fileWatcher.stopWatching()
                    menuBarStatus.stopPolling()
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
        }

        MenuBarExtra("Scarf", systemImage: menuBarStatus.icon) {
            MenuBarMenu(status: menuBarStatus, coordinator: coordinator, updater: updater)
        }
    }
}

@Observable
final class MenuBarStatus {
    private let fileService = HermesFileService()
    private var timer: Timer?

    var hermesRunning = false
    var gatewayRunning = false

    var icon: String {
        hermesRunning ? "hare.fill" : "hare"
    }

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func startHermes() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HermesPaths.hermesBinary)
        process.arguments = ["gateway", "start"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refresh()
        }
    }

    func stopHermes() {
        fileService.stopHermes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh()
        }
    }

    func restartHermes() {
        fileService.stopHermes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startHermes()
        }
    }

    private func refresh() {
        hermesRunning = fileService.isHermesRunning()
        gatewayRunning = fileService.loadGatewayState()?.isRunning ?? false
    }
}

struct MenuBarMenu: View {
    let status: MenuBarStatus
    let coordinator: AppCoordinator
    let updater: UpdaterService

    var body: some View {
        VStack {
            Label(status.hermesRunning ? "Hermes Running" : "Hermes Stopped", systemImage: status.hermesRunning ? "circle.fill" : "circle")
            Label(status.gatewayRunning ? "Gateway Running" : "Gateway Stopped", systemImage: status.gatewayRunning ? "circle.fill" : "circle")
            Divider()
            Button("Start Hermes") { status.startHermes() }
                .disabled(status.hermesRunning)
            Button("Stop Hermes") { status.stopHermes() }
                .disabled(!status.hermesRunning)
            Button("Restart Hermes") { status.restartHermes() }
                .disabled(!status.hermesRunning)
            Divider()
            Button("Open Dashboard") {
                coordinator.selectedSection = .dashboard
                NSApplication.shared.activate()
            }
            Button("New Chat") {
                coordinator.selectedSection = .chat
                NSApplication.shared.activate()
            }
            Button("View Sessions") {
                coordinator.selectedSection = .sessions
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
}
