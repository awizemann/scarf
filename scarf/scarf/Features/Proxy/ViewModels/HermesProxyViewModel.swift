import Foundation
import ScarfCore
import os

/// MainActor view-model facade over `HermesProxyService`. The service
/// holds the long-running `Process` and the log buffer; the VM tracks
/// the user-bindable form fields (provider, port) and surfaces the
/// derived "should the Start button be enabled" predicates. Keeping
/// the form state here (not on the service) means switching servers
/// in the future won't lose what the user typed into the panel.
@MainActor
@Observable
final class HermesProxyViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "HermesProxyViewModel")
    let context: ServerContext
    /// Backing service. Public so the view can read `isRunning` /
    /// `logLines` / `endpoint` reactively without re-publishing each
    /// field from this VM.
    let service: HermesProxyService

    /// Provider to launch the proxy with. Default `nous` — the only
    /// adapter registered in v0.14. `refreshProviders()` updates the
    /// picker list at appear time and on user request.
    var providerSelection: String = "nous"

    /// Port to listen on. Bound to a numeric TextField on the panel.
    /// Defaults to Hermes's `DEFAULT_PORT`.
    var portText: String = String(HermesProxyService.defaultPort)

    /// List of provider IDs surfaced by `hermes proxy providers`.
    /// Defaults to `["nous"]` while the probe is in flight so the
    /// picker is never empty.
    var availableProviders: [String] = ["nous"]

    init(context: ServerContext) {
        self.context = context
        self.service = HermesProxyService(context: context)
    }

    /// Probe the live Hermes for the registered proxy adapters. Best-
    /// effort: any error falls back to `["nous"]` so the picker stays
    /// usable.
    func refreshProviders() async {
        let providers = await service.listAvailableProviders()
        availableProviders = providers
        if !providers.contains(providerSelection), let first = providers.first {
            providerSelection = first
        }
    }

    /// Whether the Start button should be active. False while a child
    /// is already running, or when the port input doesn't parse.
    var canStart: Bool {
        guard !service.isRunning else { return false }
        return Int(portText.trimmingCharacters(in: .whitespaces)) != nil
    }

    /// Whether the Stop button should be active.
    var canStop: Bool { service.isRunning }

    /// Whether the panel should be available at all (host on the
    /// local server — remote SSH is deferred).
    var isLocal: Bool { context.id == ServerContext.local.id }

    /// `async` since round-6 P58: the service resolves the login-shell
    /// environment and forks off the main actor now (C10), so the start is a
    /// suspension rather than a synchronous freeze. The button's `Task` is
    /// what awaits it.
    func start() async {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        await service.start(
            provider: providerSelection,
            host: HermesProxyService.defaultHost,
            port: port
        )
    }

    func stop() { service.stop() }
    func clearLog() { service.clearLog() }
}
