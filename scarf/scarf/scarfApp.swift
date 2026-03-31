import SwiftUI

@main
struct ScarfApp: App {
    @State private var coordinator = AppCoordinator()
    @State private var fileWatcher = HermesFileWatcher()
    @State private var menuBarStatus = MenuBarStatus()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .environment(fileWatcher)
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

        MenuBarExtra("Scarf", systemImage: menuBarStatus.icon) {
            MenuBarMenu(status: menuBarStatus, coordinator: coordinator)
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

    private func refresh() {
        hermesRunning = fileService.isHermesRunning()
        gatewayRunning = fileService.loadGatewayState()?.isRunning ?? false
    }
}

struct MenuBarMenu: View {
    let status: MenuBarStatus
    let coordinator: AppCoordinator

    var body: some View {
        VStack {
            Label(status.hermesRunning ? "Hermes Running" : "Hermes Stopped", systemImage: status.hermesRunning ? "circle.fill" : "circle")
            Label(status.gatewayRunning ? "Gateway Running" : "Gateway Stopped", systemImage: status.gatewayRunning ? "circle.fill" : "circle")
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
            Button("Quit Scarf") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
