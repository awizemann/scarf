import SwiftUI
import AppKit
import ScarfCore
import ScarfDesign

/// The one "this feature is a Hermes plugin now" affordance (S6).
///
/// Several features left Hermes core for `plugin-catalog/` entries: Home
/// Assistant and the honcho/mem0/openviking/supermemory memory providers at
/// v0.21.6, holographic and Spotify at v0.21.7, the Singularity terminal
/// backend at v0.22.5 (see the `hasCatalog*` flags). Hermes installs them by
/// itself only on `hermes update` or, at agent/gateway start, when
/// `security.allow_lazy_installs` is on
/// (`hermes_cli/left_core_migration.py:1-25`,
/// `memory_provider_migration.py:190-197` @ v0.22.5), so a user configuring
/// one from Scarf can be left with a setting nothing reads.
///
/// The CALLER decides whether to render it (behind the feature's flag), so an
/// older host renders exactly what it did before. The roster, the install
/// and the enable go through the Plugins pane's own cached
/// ``PluginsViewModel`` — the same `plugins list` data and the same
/// `plugins install --enable -- <id>` / `plugins enable -- <id>` paths and
/// verdicts the pane uses.
struct PluginRequiredNote: View {
    /// The catalog entry name (`plugin-catalog/<id>.yaml`), which is also the
    /// installed plugin's name for these rows.
    let pluginID: String
    /// User-facing feature name, e.g. "Home Assistant".
    let feature: String
    /// A memory provider (`kind: exclusive`) is live through
    /// `memory.provider`, not `plugins.enabled` — see
    /// ``PluginsViewModel/isPluginReady(_:activatesByConfig:)``.
    var activatesByConfig = false

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.serverContext) private var serverContext
    /// Only this note's own install/enable surfaces the pane's message here.
    @State private var startedAction = false

    var body: some View {
        let viewModel = coordinator.featureViewModel(for: .plugins) { PluginsViewModel(context: serverContext) }
        let loaded = viewModel.rosterLoaded
        let installed = viewModel.pluginActivation(pluginID) != nil
        let ready = viewModel.isPluginReady(pluginID, activatesByConfig: activatesByConfig)
        let missing = loaded && !installed
        let needsEnable = loaded && installed && !ready
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(missing || needsEnable ? ScarfColor.warning : ScarfColor.foregroundMuted)
                Text(missing
                     ? "\(feature) is now the Hermes plugin “\(pluginID)”, which isn't installed on this host. It has no effect until it is."
                     : needsEnable
                     ? "\(feature) is provided by the Hermes plugin “\(pluginID)”, which is installed but not enabled, so Hermes doesn't load it."
                     : "\(feature) is provided by the Hermes plugin “\(pluginID)”.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if missing {
                    Button("Install Plugin") {
                        startedAction = true
                        // A managed host refuses the enable's config write
                        // (P47), so install without asking for it there.
                        // For a memory provider `--enable` is Hermes's own
                        // selection path (`_select_memory_provider`:
                        // prepare deps, lift `plugins.disabled`, set
                        // `memory.provider`; `plugins_cmd_install.py:689-690`).
                        viewModel.install(pluginID, enable: !viewModel.isManagedHost, showReport: false)
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isLoading)
                } else if needsEnable {
                    // For a memory provider this only lifts `plugins.disabled`
                    // (`_apply_activation` moves the key out of it); the
                    // selection itself is `memory.provider`, which the picker
                    // already wrote.
                    Button("Enable Plugin") {
                        startedAction = true
                        viewModel.enable(named: pluginID)
                    }
                    .controlSize(.small)
                    // P47: activation is read-only on a managed host, as on
                    // the Plugins pane's own Enable button.
                    .disabled(viewModel.isLoading || viewModel.isManagedHost)
                    .help(viewModel.managedBannerText ?? "")
                }
            }
            if activatesByConfig, viewModel.pendingMemorySetup == pluginID {
                // A memory provider left inactive for want of dependency
                // consent: Hermes's own next step, in Terminal
                // (``PluginsViewModel/pendingMemorySetup``).
                let line = viewModel.memorySetupCommand(pluginID)
                HStack(spacing: ScarfSpace.s2) {
                    Text(verbatim: "hermes memory setup \(pluginID)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Open in Terminal") {
                        let script = NSAppleScript(source: GatewaySetupTerminalCommand.appleScript(forShellLine: line))
                        var err: NSDictionary?
                        script?.executeAndReturnError(&err)
                        viewModel.pendingMemorySetup = nil
                    }
                    .controlSize(.small)
                }
            }
            if startedAction {
                OutcomeMessageBar(
                    text: viewModel.message,
                    kind: viewModel.messageKind,
                    onDismiss: { viewModel.dismissMessage() }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { viewModel.load() }
        .pluginDependencyConsentDialog(viewModel)
    }
}

extension View {
    /// The confirmation for a v0.21.6+ install whose `--enable` Hermes
    /// refused for want of Python dependency consent
    /// (``PluginsViewModel/pendingDependencyConsent``). The confirm button is
    /// the only way ``PluginsViewModel/enableWithDependencyConsent(_:)`` runs.
    /// `isEnabled: false` holds it back while a sheet on the same view is up.
    func pluginDependencyConsentDialog(_ viewModel: PluginsViewModel, isEnabled: Bool = true) -> some View {
        confirmationDialog(
            viewModel.pendingDependencyConsent.map { "Install \($0)'s Python dependencies?" } ?? "",
            isPresented: Binding(
                get: { isEnabled && viewModel.pendingDependencyConsent != nil },
                set: { if !$0 { viewModel.pendingDependencyConsent = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Enable and Install Dependencies") {
                if let name = viewModel.pendingDependencyConsent {
                    viewModel.enableWithDependencyConsent(name)
                }
            }
            Button("Leave Disabled", role: .cancel) { viewModel.pendingDependencyConsent = nil }
        } message: {
            Text("The plugin is installed but disabled: it declares Python dependencies, and Hermes needs your consent before adding them to its shared environment. Continuing runs `hermes plugins enable \(viewModel.pendingDependencyConsent ?? "")`, which installs those dependencies and enables the plugin. The plugin itself is not downloaded or re-scanned.")
        }
    }
}
