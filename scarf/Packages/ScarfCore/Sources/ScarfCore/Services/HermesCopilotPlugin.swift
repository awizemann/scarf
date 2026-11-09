import Foundation
#if canImport(os)
import os
#endif

/// GitHub Copilot after it LEFT Hermes core (``HermesCapabilities/hasCopilotLeftCore``,
/// v0.22.6+) for the `github-copilot` catalog plugin
/// (`plugin-catalog/github-copilot.yaml` @ v0.22.6 / v0.23.0).
///
/// On those hosts core no longer routes any Copilot id (`_COPILOT_API` /
/// `_COPILOT_ACP`, `hermes_cli/left_core_migration.py:339-340` @ v0.23.0):
/// the provider only exists when the plugin is installed under the home,
/// which Hermes itself checks as `(home / "plugins" / plugin).is_dir()`
/// (`plugin_present`, `left_core_migration.py:790-792`). Scarf mirrors that
/// check through the window's transport (``isInstalled(context:capabilities:)``)
/// and offers Copilot rows only when it passes.
///
/// On every older host (and an undetected one) ``isOffered(capabilities:pluginInstalled:)``
/// is `true`, so the tables behave exactly as before (charter C1).
public enum HermesCopilotPlugin {
    /// The catalog plugin's name, which is also its directory under
    /// `$HERMES_HOME/plugins/` and the id ``PluginRequiredNote`` installs.
    public static let pluginID = "github-copilot"

    /// `_COPILOT_API` (`left_core_migration.py:339` @ v0.23.0).
    public static let apiProviderIDs: Set<String> = [
        "copilot", "github-copilot", "github-models", "github-model", "github",
    ]
    /// `_COPILOT_ACP` (`left_core_migration.py:340` @ v0.23.0).
    public static let acpProviderIDs: Set<String> = [
        "copilot-acp", "github-copilot-acp", "copilot-acp-agent",
    ]
    public static let providerIDs: Set<String> = apiProviderIDs.union(acpProviderIDs)

    /// Env vars only Copilot read in core (`left_core_migration.py:353-358`).
    public static let envVars: Set<String> = ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]

    /// True for any spelling of a Copilot provider id (trimmed, case-insensitive).
    public static func isCopilotProvider(_ providerID: String?) -> Bool {
        guard let id = providerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !id.isEmpty else { return false }
        return providerIDs.contains(id)
    }

    /// Whether Copilot rows may be offered on this host.
    public static func isOffered(capabilities: HermesCapabilities, pluginInstalled: Bool) -> Bool {
        !capabilities.hasCopilotLeftCore || pluginInstalled
    }

    /// Whether `providerID` is a Copilot id this host can't route because the
    /// plugin is missing — the case that shows ``PluginRequiredNote``.
    public static func needsPlugin(
        _ providerID: String?, capabilities: HermesCapabilities, pluginInstalled: Bool
    ) -> Bool {
        isCopilotProvider(providerID) && !isOffered(capabilities: capabilities, pluginInstalled: pluginInstalled)
    }

    /// `plugin_present("github-copilot", home)` through the window's transport.
    /// Synchronous transport I/O (an `ssh` stat on a remote host): call it off
    /// the main actor. Returns `false` without any I/O on hosts where Copilot
    /// is still core — the answer is irrelevant there.
    public nonisolated static func isInstalled(
        context: ServerContext, capabilities: HermesCapabilities
    ) -> Bool {
        guard capabilities.hasCopilotLeftCore else { return false }
        let installed = isInstalled(pluginsDir: context.paths.pluginsDir, transport: context.makeTransport())
        record(installed, for: context)
        return installed
    }

    /// Last probe result per connection (``HermesVersionCache/key(for:)``),
    /// so callers that must not do I/O (error-hint classification) reuse it.
    #if canImport(os)
    private static let lastProbe = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
    #endif

    static func record(_ installed: Bool, for context: ServerContext) {
        #if canImport(os)
        let key = HermesVersionCache.key(for: context)
        lastProbe.withLock { $0[key] = installed }
        #endif
    }

    /// Whether Copilot is offered for `context`, from what is already known —
    /// no I/O. True on hosts where Copilot is still core (and undetected
    /// ones), so they behave as before; on a left-core host it is the last
    /// ``isInstalled(context:capabilities:)`` result, `false` until one ran.
    public static func knownOffered(context: ServerContext, capabilities: HermesCapabilities) -> Bool {
        guard capabilities.hasCopilotLeftCore else { return true }
        #if canImport(os)
        let key = HermesVersionCache.key(for: context)
        return lastProbe.withLock { $0[key] } ?? false
        #else
        return false
        #endif
    }

    /// ``knownOffered(context:capabilities:)`` with this process's cached
    /// `hermes --version` result (``HermesVersionCache/cached(for:)``, a
    /// lock read); an unprobed host counts as undetected.
    public static func knownOffered(context: ServerContext) -> Bool {
        knownOffered(context: context, capabilities: HermesVersionCache.shared.cached(for: context) ?? .empty)
    }

    /// Installed AND loadable, for callers that already hold a transport.
    ///
    /// The directory alone is not enough: `plugin_present` is only Hermes's
    /// migration-notice check ("enabled or not"). Routing needs the plugin
    /// LOADED, and the loader is opt-in — it skips a plugin in
    /// `plugins.disabled` or missing from `plugins.enabled`
    /// (`hermes_cli/plugins.py:1337-1349` @ v0.23.0). `plugins install` asks
    /// "Enable now? [y/N]" (`plugins_cmd_install.py:628`), so installed but
    /// not enabled is an ordinary state. Same rule as
    /// `HermesPluginDirectoryScanner` / `PluginsViewModel.isPluginReady`.
    /// `config.yaml` is the home's, i.e. the parent of `pluginsDir`.
    public nonisolated static func isInstalled(pluginsDir: String, transport: any ServerTransport) -> Bool {
        guard transport.stat(pluginsDir + "/" + pluginID)?.isDirectory == true else { return false }
        let configPath = (pluginsDir as NSString).deletingLastPathComponent + "/config.yaml"
        let yaml = (try? transport.readFile(configPath)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let lists = HermesPluginList.parseConfigActivationLists(yaml)
        return HermesPluginList.status(name: pluginID, enabled: lists.enabled, disabled: lists.disabled) == .enabled
    }
}
