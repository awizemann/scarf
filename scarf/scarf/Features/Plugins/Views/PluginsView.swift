import SwiftUI
import ScarfCore
import ScarfDesign

struct PluginsView: View {
    // Coordinator-cached (t-aud24) so it survives section switches; still
    // observed via Observation (property reads in `body`).
    let viewModel: PluginsViewModel
    @State private var installIdentifier = ""
    @State private var showInstall = false
    @State private var pendingRemove: HermesPlugin?
    /// Enable-on-install choice, surfaced in the install sheet so the CLI
    /// gets an explicit `--enable` / `--no-enable` instead of a prompt it
    /// answers "no" to on a non-tty.
    @State private var enableOnInstall = true
    /// Set when the user asks to enable a plugin that declares
    /// `tool_override` — the grant is confirmed explicitly before any
    /// `--allow-tool-override` reaches the CLI.
    @State private var pendingToolOverride: HermesPlugin?
    /// v0.16 Spotify sign-in sheet state. Only rendered when the spotify
    /// plugin is present and isV016OrLater is true.
    @State private var showSpotifySignIn = false
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(viewModel: PluginsViewModel) {
        self.viewModel = viewModel
    }


    var body: some View {
        VStack(spacing: 0) {
            header
            if viewModel.isLoading && viewModel.plugins.isEmpty {
                ProgressView().padding()
            } else if viewModel.plugins.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Plugins")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading plugins…",
            isEmpty: viewModel.plugins.isEmpty
        )
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showInstall) { installSheet }
        .sheet(isPresented: $showSpotifySignIn) {
            SpotifySignInSheet(onSignedIn: {
                // No state to refresh in this view yet — chat picks
                // up the new token on next session start. Keep the
                // hook so a future "auth status" indicator can rebind.
            })
        }
        .confirmationDialog(
            pendingRemove.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let plugin = pendingRemove { viewModel.remove(plugin) }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        }
        .confirmationDialog(
            pendingToolOverride.map { "Let \($0.name) replace built-in tools?" } ?? "",
            isPresented: Binding(get: { pendingToolOverride != nil }, set: { if !$0 { pendingToolOverride = nil } }),
            titleVisibility: .visible
        ) {
            Button("Enable and Grant Override", role: .destructive) {
                if let plugin = pendingToolOverride { viewModel.enable(plugin, allowToolOverride: true) }
                pendingToolOverride = nil
            }
            Button("Enable Without Override") {
                if let plugin = pendingToolOverride { viewModel.enable(plugin, allowToolOverride: false) }
                pendingToolOverride = nil
            }
            Button("Cancel", role: .cancel) { pendingToolOverride = nil }
        } message: {
            Text("This plugin declares `tool_override`. Granting it lets the plugin take over built-in tools such as `shell_exec` and `write_file` for every session on this host.")
        }
        .sheet(item: Binding(
            get: { viewModel.installReport },
            set: { if $0 == nil { viewModel.installReport = nil } }
        )) { report in
            installReportSheet(report)
        }
    }

    /// Shows what `plugins install` actually said. Previously discarded:
    /// the after-install notes, the unset `requires_env` names, and the
    /// gateway-restart instruction.
    private func installReportSheet(_ report: PluginsViewModel.InstallReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                report.failed ? "Install failed"
                    : (report.outcome.enabled ? "Installed and enabled" : "Installed — not enabled"),
                systemImage: report.failed ? "xmark.octagon.fill"
                    : (report.outcome.enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            )
            .font(.headline)
            .foregroundStyle(report.failed ? ScarfColor.danger : (report.outcome.enabled ? ScarfColor.success : ScarfColor.warning))

            if !report.outcome.missingEnvVars.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set these in `~/.hermes/.env` before the plugin will work:")
                        .font(.caption.bold())
                    ForEach(report.outcome.missingEnvVars, id: \.self) { name in
                        Text(name).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if report.outcome.needsGatewayRestart {
                Label("Restart the gateway for this plugin to take effect.", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(report.outcome.notes)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Done") { viewModel.installReport = nil }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 380)
    }

    private var header: some View {
        ScarfPageHeader(
            "Plugins",
            subtitle: "Hermes plugins discovered from `~/.hermes/plugins/`."
        ) {
            HStack(spacing: ScarfSpace.s2) {
                if let msg = viewModel.message {
                    Label(msg, systemImage: "info.circle.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.success)
                }
                Button("Reload") { viewModel.load(force: true) }
                    .buttonStyle(ScarfGhostButton())
                Button {
                    installIdentifier = ""
                    showInstall = true
                } label: {
                    Label("Install", systemImage: "plus")
                }
                .buttonStyle(ScarfPrimaryButton())
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No plugins installed")
                .foregroundStyle(.secondary)
            Text("Plugins extend hermes with custom tools, providers, or memory backends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Install a Plugin") {
                installIdentifier = ""
                showInstall = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                // v0.16 Spotify sign-in affordance: surface when the
                // spotify plugin is present and we're on v0.16+. Reuses
                // the same SpotifySignInSheet and SpotifyAuthFlow as the
                // SkillsView placement (pre-v0.16 only).
                if capabilitiesStore?.capabilities.isV016OrLater == true,
                   viewModel.plugins.contains(where: { $0.name == "spotify" }) {
                    spotifyAuthRow
                        .padding()
                }
                ForEach(viewModel.plugins) { plugin in
                    row(plugin)
                }
            }
            .padding()
        }
    }

    private func row(_ plugin: HermesPlugin) -> some View {
        HStack(spacing: 12) {
            // Redundant with the activation badge in the row text.
            Image(systemName: plugin.activation.isActive ? "app.badge.checkmark.fill" : "app.badge")
                .foregroundStyle(plugin.activation.isActive ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                    if !plugin.version.isEmpty {
                        Text(plugin.version)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    // "not enabled" is its own state: installed on disk but
                    // in neither config list, so the runtime never loads it.
                    // Showing it as plain "disabled" (or, as before, as
                    // enabled) misreports what Hermes will do.
                    switch plugin.activation {
                    case .enabled: EmptyView()
                    case .disabled: ScarfBadge("disabled", kind: .danger)
                    case .notEnabled: ScarfBadge("not enabled", kind: .warning)
                    }
                    // v0.14 — surface plugins that replace a built-in
                    // tool with a visible badge so users notice
                    // overridden behavior. The flag comes from the
                    // plugin's manifest (`tool_override: true`).
                    if plugin.toolOverride {
                        ScarfBadge("tool-override", kind: .info)
                    }
                }
                if !plugin.description.isEmpty {
                    Text(plugin.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !plugin.source.isEmpty {
                    Text(plugin.source)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            // Name, version, activation badge, description and source read
            // as one announcement; the action buttons stay outside it.
            .accessibilityElement(children: .combine)
            Spacer()
            Button(plugin.activation.isActive ? "Disable" : "Enable") {
                if plugin.activation.isActive {
                    viewModel.disable(plugin)
                } else if plugin.toolOverride && viewModel.supportsToolOverrideFlags {
                    // The grant is a real privilege escalation, so it goes
                    // through an explicit confirmation rather than riding
                    // along with the enable.
                    pendingToolOverride = plugin
                } else {
                    viewModel.enable(plugin)
                }
            }
            .controlSize(.small)
            // Every row repeats these three verbs; the plugin name is what
            // makes them distinguishable to Voice Control and VoiceOver.
            .accessibilityLabel(
                plugin.activation.isActive
                    ? Text("Disable \(plugin.name)")
                    : Text("Enable \(plugin.name)")
            )
            Button("Update") { viewModel.update(plugin) }
                .controlSize(.small)
                .accessibilityLabel(Text("Update \(plugin.name)"))
            Button("Remove", role: .destructive) { pendingRemove = plugin }
                .controlSize(.small)
                .accessibilityLabel(Text("Remove \(plugin.name)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    /// Renders the v0.16 Spotify auth row in the plugins list when the
    /// spotify plugin is discovered. Tapping opens `SpotifySignInSheet`
    /// which drives `hermes auth spotify` end-to-end in-app.
    private var spotifyAuthRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to Spotify")
                    .font(.callout.weight(.medium))
                Text("Authorise Hermes to control playback, search, and library actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In") { showSpotifySignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Plugin")
                .font(.headline)
            Text("Provide a Git URL (https://github.com/...) or a shorthand like `owner/repo`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The placeholder is a format example, not a name — as the
            // field's only label VoiceOver would read the whole sample URL
            // and Voice Control would have nothing sayable to target.
            TextField("github.com/owner/plugin-repo  or  owner/repo", text: $installIdentifier)
                .accessibilityLabel(Text("Plugin repository"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Toggle("Enable after installing", isOn: $enableOnInstall)
                .accessibilityHint("Passes --enable to hermes plugins install. Turn off to install the plugin without activating it.")
            Text("Hermes installs plugins disabled unless told otherwise. Portable Agent Plugin packages always install disabled.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showInstall = false }
                Button("Install") {
                    viewModel.install(installIdentifier, enable: enableOnInstall)
                    showInstall = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(installIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 200)
    }
}
