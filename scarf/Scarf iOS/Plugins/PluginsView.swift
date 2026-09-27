import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS read-only Plugins view (v2.6).
///
/// Same sources as the Mac Plugins pane: `hermes plugins list --json` on
/// v0.16+ hosts (`hasPluginsListJSON`), otherwise the shared
/// `HermesPluginDirectoryScanner` walk with activation read from
/// config.yaml's `plugins.enabled` / `plugins.disabled` — the lists
/// `_plugin_status` reads (`hermes_cli/plugins_cmd.py:1638-1651` @
/// v2026.9.24). This used to derive state from a `.disabled` marker file
/// Hermes never writes, so every plugin, including ones Hermes does not
/// load, showed "Enabled" (S10-F4).
///
/// Install / update / remove / enable / disable verbs stay on Mac for
/// v2.6 — installing a plugin from a phone is an unusual flow.
struct PluginsView: View {
    let config: IOSServerConfig

    @State private var plugins: [PluginRow] = []
    @State private var isLoading = true
    @State private var lastError: String?
    @Environment(\.serverContext) private var contextFromEnv

    private var context: ServerContext {
        config.toServerContext(id: contextFromEnv.id)
    }

    var body: some View {
        List {
            if let err = lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ScarfColor.warning)
                }
            }

            if plugins.isEmpty && !isLoading {
                Section {
                    ContentUnavailableView(
                        "No plugins installed",
                        systemImage: "app.badge.checkmark",
                        description: Text("Hermes plugins live under `~/.hermes/plugins/<name>/`. Install one with `hermes plugins install <repo>` from the Mac app.")
                    )
                }
            } else {
                ForEach(plugins) { plugin in
                    Section(plugin.name) {
                        HStack {
                            statusBadge(plugin.activation)
                            if !plugin.version.isEmpty {
                                Text("v\(plugin.version)")
                                    .font(ScarfFont.monoSmall)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if !plugin.source.isEmpty {
                            LabeledContent("Source", value: plugin.source)
                                .font(.caption.monospaced())
                        }
                        if !plugin.description.isEmpty {
                            Text(plugin.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // The `--json` roster carries no path.
                        if !plugin.path.isEmpty {
                            Text(plugin.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { await load() }
    }

    /// Three states, as Hermes reports them. "Not enabled" is installed
    /// but in neither config list, so the runtime never loads it.
    @ViewBuilder
    private func statusBadge(_ activation: HermesPluginActivation) -> some View {
        switch activation {
        case .enabled: ScarfBadge("Enabled", kind: .success)
        case .disabled: ScarfBadge("Disabled", kind: .danger)
        case .notEnabled: ScarfBadge("Not enabled", kind: .warning)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let ctx = context
        let caps = await HermesVersionCache.shared.capabilities(for: ctx)
        var rows: [PluginRow]?
        if caps.hasPluginsListJSON {
            let transport = ctx.makeTransport()
            // `parseJSON` returns nil (not []) for output it can't read, so a
            // failed or odd call falls through to the directory walk rather
            // than rendering "no plugins".
            if let result = try? await transport.asyncRunProcess(
                executable: ctx.paths.hermesBinary,
                args: ["plugins", "list", "--json"],
                stdin: nil,
                timeout: 45
            ), let entries = HermesPluginList.parseJSON(result.stdoutString) {
                rows = entries.map { entry in
                    PluginRow(
                        name: entry.name,
                        version: entry.version,
                        source: entry.source,
                        description: entry.description,
                        path: "",
                        activation: entry.status
                    )
                }
            }
        }
        if let rows {
            self.plugins = rows
            return
        }
        let dir = ctx.paths.pluginsDir
        self.plugins = await Task.detached {
            HermesPluginDirectoryScanner.walk(dir: dir, context: ctx).map { entry in
                PluginRow(
                    name: entry.name,
                    version: entry.version,
                    source: entry.source,
                    description: "",
                    path: entry.path,
                    activation: entry.activation
                )
            }
        }.value
    }

    private struct PluginRow: Identifiable, Sendable {
        var id: String { name + "|" + path }
        let name: String
        let version: String
        let source: String
        let description: String
        let path: String
        let activation: HermesPluginActivation
    }
}
