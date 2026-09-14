import Foundation
import ScarfCore
import os

/// Connection/configuration status for a messaging platform, used for indicator dots in the picker.
enum PlatformConnectivity: Sendable, Equatable {
    case connected              // Gateway reports the platform online
    case configured             // Platform has a config block but gateway isn't reporting it as connected
    case notConfigured          // No signal that this platform has been set up
    case error(String)          // Gateway reports an error for this platform
}

@Observable
final class ToolsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ToolsViewModel")
    let context: ServerContext

    init(context: ServerContext = .local) {
        self.context = context
    }

    var selectedPlatform: HermesToolPlatform = KnownPlatforms.cli
    var toolsets: [HermesToolset] = []
    var mcpStatus: String = ""
    var isLoading = false
    var connectivity: [String: PlatformConnectivity] = [:]
    /// Platforms with configuration on disk, and whether that has been read
    /// yet. `ToolsView` needs both to answer `isVisible(on:isConfigured:)`:
    /// an empty set before the first load means "not looked yet", not "none".
    private(set) var configuredPlatformNames: Set<String> = []
    private(set) var hasLoadedPlatforms = false

    @MainActor
    func load() async {
        isLoading = true
        await loadPlatforms()
        await loadTools(for: selectedPlatform)
        await loadMCPStatus()
        isLoading = false
    }

    @MainActor
    func switchPlatform(_ platform: HermesToolPlatform) async {
        selectedPlatform = platform
        await loadTools(for: platform)
    }

    /// Snap `selectedPlatform` back to `cli` once the post-load roster no
    /// longer offers it (round-3 decision 8), and reload the tool list for
    /// the platform we landed on so no toggle in the pane still writes
    /// `--platform <sub-floor name>`.
    @MainActor
    func reconcileSelection(visible: [HermesToolPlatform]) async {
        let reconciled = KnownPlatforms.reconcile(selection: selectedPlatform, against: visible)
        guard reconciled.name != selectedPlatform.name else { return }
        logger.info("selection \(self.selectedPlatform.name, privacy: .public) left the roster; snapping to \(reconciled.name, privacy: .public)")
        await switchPlatform(reconciled)
    }

    @MainActor
    func toggleTool(_ tool: HermesToolset) async {
        guard let idx = toolsets.firstIndex(where: { $0.name == tool.name }) else { return }
        toolsets[idx].enabled.toggle()
        let newEnabled = toolsets[idx].enabled

        let action = newEnabled ? "enable" : "disable"
        let result = await runHermes(
            HermesToolsToggle.argv(toolset: tool.name,
                                   platform: selectedPlatform.name,
                                   enabled: newEnabled))

        // NOT the exit code. `tools enable|disable` prints every refusal it
        // has — unknown platform, unknown toolset, a platform-restricted
        // toolset, an unknown MCP server, and `save_config`'s managed arm —
        // and exits 0 for all of them, then prints `✓ Enabled: <name>` from a
        // list computed before the save could refuse
        // (`hermes_cli/tools_config_mcp.py:237-285`, `config.py:2316-2318` @
        // v2026.9.7). See ``HermesToolsToggle``. The per-bot twin
        // (`BotAgentViewModel.setToolset`) judges the same way.
        let outcome = HermesToolsToggle.judge(output: result.output, exitCode: result.exitCode)
        if !outcome.succeeded {
            if let idx = toolsets.firstIndex(where: { $0.name == tool.name }) {
                toolsets[idx].enabled = !newEnabled
            }
            // The revert alone is invisible: the switch snaps back and the
            // user has no idea whether they mis-clicked or the CLI refused.
            // Reuse the Settings extraction so the CLI's own sentence (or a
            // Python traceback tail) becomes one readable line.
            toggleFailureMessage = Self.toggleFailureSummary(
                outcome: outcome, output: result.output, action: action, toolset: tool.name
            )
            logger.warning("tools \(action, privacy: .public) refused (exit \(result.exitCode))")
        } else {
            toggleFailureMessage = nil
        }
    }

    /// Three branches, not two (the ``HermesMemoryResetVerdict/failureSummary``
    /// shape, round-6 P54b/P59). `.unconfirmed` is gated on the CONFIDENCE
    /// ALONE — never on whether there is a line to quote. A two-way `if`
    /// reaches the honest sentence only when the output was EMPTY, so an
    /// exit-0 run that printed something the verdict does not recognise had
    /// its unrelated tail line rendered as the toggle's refusal: a sentence
    /// Hermes never said, presented as its reason.
    static func toggleFailureSummary(
        outcome: HermesCLIOutcome,
        output: String,
        action: String,
        toolset: String
    ) -> String {
        if outcome.confidence == .unconfirmed {
            let verb = "hermes tools \(action)"
            return String(localized: "\(verb) printed no result. Check the host.")
        }
        // Reuse the Settings extraction so the CLI's own sentence (or a
        // Python traceback tail) becomes one readable line.
        if let reason = outcome.detail ?? SettingsViewModel.failureReason(from: output) {
            return String(localized: "Couldn’t \(action) \(toolset): \(reason)")
        }
        return String(localized: "Couldn’t \(action) \(toolset)")
    }

    /// Sticky failure banner for the last toggle. `nil` = no failure
    /// outstanding. Cleared by a successful toggle or by `dismissToggleFailure`.
    var toggleFailureMessage: String?

    func dismissToggleFailure() { toggleFailureMessage = nil }

    /// Enumerate all known platforms and compute a connectivity status per platform.
    ///
    /// Source of truth:
    /// - `KnownPlatforms.all` defines every platform the app knows about.
    /// - `~/.hermes/gateway_state.json` tells us which are currently connected.
    /// - `~/.hermes/config.yaml` top-level keys (`discord:`, `whatsapp:`, etc.) tell us which have been configured.
    ///
    /// The ROSTER is not "always show these": the picker feeds
    /// `hermes tools enable … --platform <name>`, so offering a platform the
    /// host has no adapter for is a guaranteed CLI failure (charter C5).
    /// `ToolsView` filters this list through `KnownPlatforms.visible(on:…)`
    /// — the same seam the Platforms list uses — rather than each surface
    /// inventing its own rule.
    @MainActor
    private func loadPlatforms() async {
        let ctx = context
        let gatewayState: GatewayState? = await Task.detached {
            HermesFileService(context: ctx).loadGatewayState()
        }.value

        // ONE detector, shared with the Platforms list. This surface used to
        // carry its own `hasSuffix(":")` scan, which saw neither a
        // preserved-empty section (`slack: {}`) nor a nested
        // `platforms.<name>.…` block — so with the roster now GATED on the
        // same answer, a second, weaker detector would hide a configured row
        // here while showing it there.
        let configuredNames = await Task.detached {
            PlatformsViewModel.computeConfiguredPlatforms(context: ctx)
        }.value
        var status: [String: PlatformConnectivity] = [:]

        for platform in KnownPlatforms.all {
            if let pState = gatewayState?.platforms?[platform.name] {
                if let err = pState.error, !err.isEmpty {
                    status[platform.name] = .error(err)
                } else if pState.connected == true {
                    status[platform.name] = .connected
                } else if configuredNames.contains(platform.name) || platform.name == "cli" {
                    status[platform.name] = .configured
                } else {
                    status[platform.name] = .notConfigured
                }
            } else if configuredNames.contains(platform.name) || platform.name == "cli" {
                status[platform.name] = .configured
            } else {
                status[platform.name] = .notConfigured
            }
        }

        connectivity = status
        configuredPlatformNames = configuredNames
        hasLoadedPlatforms = true
    }

    @MainActor
    private func loadTools(for platform: HermesToolPlatform) async {
        let result = await runHermes(["tools", "list", "--platform", platform.name])
        toolsets = parseToolsList(result.output)
    }

    @MainActor
    private func loadMCPStatus() async {
        let result = await runHermes(["mcp", "list"])
        mcpStatus = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Delegates to `ScarfCore.HermesToolsList` — the same parse the per-bot
    /// Agent surface uses, so a toolset row means the same thing on both.
    private func parseToolsList(_ output: String) -> [HermesToolset] {
        HermesToolsList.parse(output)
    }

    private nonisolated func runHermes(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        let ctx = context
        return await OffPool.run { ctx.runHermes(arguments) }
    }
}
