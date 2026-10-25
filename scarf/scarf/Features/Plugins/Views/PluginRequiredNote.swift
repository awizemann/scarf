import SwiftUI
import ScarfCore
import ScarfDesign

/// The one "this feature is a Hermes plugin now" affordance (S6).
///
/// Several features left Hermes core for `plugin-catalog/` entries: Home
/// Assistant and the honcho/mem0/openviking/supermemory memory providers at
/// v0.21.6, holographic at v0.21.7, the Singularity terminal backend at
/// v0.22.5 (see the `hasCatalog*` flags). Hermes installs them by itself only
/// on `hermes update` or, at agent/gateway start, when
/// `security.allow_lazy_installs` is on
/// (`hermes_cli/left_core_migration.py:1-25`,
/// `memory_provider_migration.py:190-197` @ v0.22.5), so a user configuring
/// one from Scarf can be left with a setting nothing reads.
///
/// The CALLER decides whether to render it (behind the feature's flag), so an
/// older host renders exactly what it did before. The roster and the install
/// go through the Plugins pane's own cached ``PluginsViewModel`` — the same
/// `plugins list` data and `plugins install --enable -- <id>` path the pane
/// uses — so there is one install verdict, not two.
struct PluginRequiredNote: View {
    /// The catalog entry name (`plugin-catalog/<id>.yaml`), which is also the
    /// installed plugin's name for these rows.
    let pluginID: String
    /// User-facing feature name, e.g. "Home Assistant".
    let feature: String

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.serverContext) private var serverContext
    /// Only this note's own install surfaces the pane's message here.
    @State private var startedInstall = false

    var body: some View {
        let viewModel = coordinator.featureViewModel(for: .plugins) { PluginsViewModel(context: serverContext) }
        let missing = viewModel.rosterLoaded && !viewModel.hasPlugin(pluginID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(missing ? ScarfColor.warning : ScarfColor.foregroundMuted)
                Text(missing
                     ? "\(feature) is now the Hermes plugin “\(pluginID)”, which isn't installed on this host. Settings here have no effect until it is."
                     : "\(feature) is provided by the Hermes plugin “\(pluginID)”.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if missing {
                    Button("Install Plugin") {
                        startedInstall = true
                        // A managed host refuses the enable's config write
                        // (P47), so install without asking for it there.
                        viewModel.install(pluginID, enable: !viewModel.isManagedHost, showReport: false)
                    }
                    .controlSize(.small)
                    .disabled(viewModel.isLoading)
                }
            }
            if startedInstall {
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
    /// (``PluginsViewModel/pendingDependencyConsent``). `--yes-deps` reaches
    /// the CLI only through the confirm button here. `isEnabled: false` holds
    /// it back while a sheet on the same view is up.
    func pluginDependencyConsentDialog(_ viewModel: PluginsViewModel, isEnabled: Bool = true) -> some View {
        confirmationDialog(
            viewModel.pendingDependencyConsent.map { "Install \($0)'s Python dependencies?" } ?? "",
            isPresented: Binding(
                get: { isEnabled && viewModel.pendingDependencyConsent != nil },
                set: { if !$0 { viewModel.pendingDependencyConsent = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Install Dependencies and Enable") {
                if let identifier = viewModel.pendingDependencyConsent {
                    viewModel.installWithDependencyConsent(identifier)
                }
            }
            Button("Leave Disabled", role: .cancel) { viewModel.pendingDependencyConsent = nil }
        } message: {
            Text("The plugin is installed but disabled: it declares Python dependencies, and Hermes needs your consent before adding them to its shared environment. Continuing reinstalls the plugin with `--yes-deps` and enables it.")
        }
    }
}
