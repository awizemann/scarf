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
            // Hoisted OUT of `list`: the deprecated-import compat report is
            // about the host's plugin directory, not about the rows Scarf
            // managed to render. Inside `list` it was unreachable in exactly
            // the case that matters most — a roster that came back empty
            // because every plugin failed to load — so the one banner
            // explaining WHY never appeared.
            compatBanner
                .padding(.horizontal)
                .padding(.top, ScarfSpace.s2)
            managedBanner
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
                OutcomeMessageBar(
                    text: viewModel.message,
                    kind: viewModel.messageKind,
                    onDismiss: { viewModel.dismissMessage() }
                )
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

    /// The ONE managed-install banner (P47 / round-5 decision 1). Nothing
    /// else in the pane repeats it; the two activation controls are simply
    /// disabled. See ``PluginsViewModel/managedBannerText`` for why the lock
    /// is scoped to activation rather than to the whole pane.
    @ViewBuilder
    private var managedBanner: some View {
        if let text = viewModel.managedBannerText {
            HStack(alignment: .top, spacing: ScarfSpace.s2) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text(text)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, ScarfSpace.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScarfColor.backgroundSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This Hermes installation is managed; plugin activation is read-only")
        }
    }

    /// v0.21.1 — `hermes plugins compat`: installed plugins still importing
    /// module paths the Sep 2026 decomposition removes. After the removal
    /// date those plugins are simply not loaded, so this is the only warning
    /// a user gets before a plugin goes quiet. Nothing renders when the
    /// command didn't run (older host) or found nothing.
    @ViewBuilder
    private var compatBanner: some View {
        if let report = viewModel.compatReport, report.isAffected {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    report.inEffect
                        ? "\(report.affectedNames.count) plugin(s) are no longer loaded"
                        : "\(report.affectedNames.count) plugin(s) stop loading on \(report.removalDate)",
                    systemImage: report.inEffect ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(report.inEffect ? ScarfColor.danger : ScarfColor.warning)
                Text("They import Hermes module paths removed by the Sep 2026 decomposition. Update the plugin, or set `plugins.allow_deprecated_imports: true` in config.yaml to force-load it while the compat layer lasts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(report.affectedNames, id: \.self) { name in
                    let hits = report.hits(for: name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name) — \(hits.count) import(s)")
                            .font(.caption.monospaced().bold())
                        ForEach(hits) { hit in
                            Text("\(hit.file):\(hit.line)  \(hit.old) → \(hit.new)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((report.inEffect ? ScarfColor.danger : ScarfColor.warning).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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
                    // v0.21.1 — this plugin is one of the ones
                    // `plugins compat` flagged. The badge puts the finding
                    // on the row the user acts on; the banner above carries
                    // the file:line detail.
                    if let report = viewModel.compatReport,
                       let hits = report.plugins[plugin.name] {
                        ScarfBadge(
                            report.inEffect ? "not loaded" : "breaks \(report.removalDate)",
                            kind: report.inEffect ? .danger : .warning
                        )
                        .help("\(hits.count) import(s) of module paths removed by the Sep 2026 decomposition.")
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
            // P47: activation is the one plugin action `is_managed()` refuses
            // (`_set_plugin_enabled` → `save_config`). Update and Remove work
            // on the plugin directory, which Hermes never guards, so they stay
            // live — see `PluginsViewModel.managedBannerText`.
            .disabled(viewModel.isManagedHost)
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
            // P47: the same refused write, one step earlier — `cmd_install`'s
            // `--enable` arm is a `save_config` door
            // (`hermes_cli/plugins_cmd.py:754-755`). A `.disabled` toggle keeps
            // whatever value it held, and this one DEFAULTS to on, so the
            // binding reads `false` on a managed host rather than leaving a
            // greyed-out switch that still sends `--enable`. `enableOnInstall`
            // itself is untouched, so unlocking restores the user's choice.
            Toggle("Enable after installing", isOn: Binding(
                get: { viewModel.isManagedHost ? false : enableOnInstall },
                set: { enableOnInstall = $0 }
            ))
                .disabled(viewModel.isManagedHost)
                .accessibilityHint("Passes --enable to hermes plugins install. Turn off to install the plugin without activating it.")
            Text("Hermes installs plugins disabled unless told otherwise. Portable Agent Plugin packages always install disabled.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showInstall = false }
                Button("Install") {
                    viewModel.install(
                        installIdentifier,
                        enable: enableOnInstall && !viewModel.isManagedHost
                    )
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
