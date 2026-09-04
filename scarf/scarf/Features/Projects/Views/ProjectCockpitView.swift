import SwiftUI
import ScarfCore
import ScarfDesign

/// Per-project "mission control" — the aggregate destination the
/// Phase-1 design calls for. One place that owns a project across every
/// facet, rendered from its first-class `ScarfProject` record.
///
/// **Header**: name · root path · bound model · host badges.
/// **Panels** (reuse where one already exists): Sessions
/// (`ProjectSessionsView`), Board (`ProjectKanbanTab`, gated on
/// `hasKanban`), and new lightweight read-only panels — Context
/// (AGENTS.md block), Cron (`[proj:]`/`[tmpl:]` jobs), Memory (MEMORY.md
/// block), Secrets (ref NAMES only — SECRET-SAFE), Templates.
///
/// Mini-apps are Milestone 2; **Fleet** (Milestone 3 — the
/// fleet/portfolio dimension: where the project is materialized across
/// servers + per-host config drift + apply-to-fleet) is the last panel.
/// Tool/skill scoping is deferred (upstream hermes-agent#45958), so there
/// is deliberately no Scope panel yet.
struct ProjectCockpitView: View {
    let project: ProjectEntry

    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(ServerRegistry.self) private var serverRegistry
    @Environment(AppCoordinator.self) private var coordinator

    @State private var viewModel: ProjectCockpitViewModel?
    @State private var selectedPanel: CockpitPanel = .sessions
    @State private var showDoctor = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.top)
                .padding(.bottom, 10)
            if viewModel?.needsUpgrade == true {
                upgradeBanner
                    .padding(.horizontal)
                    .padding(.bottom, 10)
            }
            if let health = viewModel?.health {
                let mine = health.issues(forProjectPath: project.path, name: project.name)
                if !mine.isEmpty {
                    healthRow(mine)
                        .padding(.horizontal)
                        .padding(.bottom, 10)
                }
            }
            Divider()
            panelBar
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            panelContent
                // Cap the reported IDEAL height so no panel's intrinsic
                // content (e.g. the Mini-apps list, or a tall empty state)
                // bubbles up through `.windowResizability(.contentMinSize)`
                // and grows the window on panel switch. `maxHeight: .infinity`
                // still fills the actual window; `minHeight: 0` allows it to
                // shrink. Mirrors the cap in ProjectSessionsView / RichChatView.
                .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 400, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: project.id) {
            // Rebuild the VM when the selected project changes so stale
            // facet data doesn't bleed across projects. Land on a safe
            // panel while loading, then prefer Dashboard once we know the
            // project has one (familiar landing for legacy dashboard
            // projects); otherwise stay on Sessions.
            selectedPanel = .sessions
            let vm = ProjectCockpitViewModel(context: serverContext, project: project)
            viewModel = vm
            await vm.load()
            if vm.dashboard != nil { selectedPanel = .dashboard }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            // `.watcher`: short-circuits on an unchanged facet signature
            // (one batched stat instead of ~10 reads) and never triggers a
            // doctor scan. See `ProjectCockpitViewModel.LoadReason`.
            Task { await viewModel?.load(force: true, reason: .watcher) }
        }
        .sheet(isPresented: $showDoctor, onDismiss: {
            // The doctor writes the registry and project records, so the
            // cockpit's facets — and its own health line — are stale once it
            // closes.
            Task { await viewModel?.load(force: true, recheckHealth: true) }
        }) {
            ProjectDoctorSheet()
        }
    }

    // MARK: - Health row

    /// Shown only when the last reconciliation pass found something wrong
    /// with THIS project. A "no issues" row every time you open a project
    /// would be noise, and a registry-wide count here would blame this
    /// project for another one's problem; the header's stethoscope button is
    /// the always-available way into the full report.
    private func healthRow(_ issues: [ProjectDoctorFinding]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .foregroundStyle(issues.contains { $0.severity == .high } ? ScarfColor.danger : ScarfColor.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Project setup needs attention")
                    .font(.callout.weight(.medium))
                Text(issues.count == 1
                    ? issues[0].title
                    : "\(issues.count) issues with this project's setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Open Project Doctor") { showDoctor = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.warning.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.title2.bold())
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    modelBadge
                    hostBadges
                }
                .padding(.top, 2)
            }
            Spacer()
            headerActions
        }
    }

    /// Per-project actions promoted from the old dashboard header. Refresh
    /// reloads every facet (incl. the dashboard widgets); the folder button
    /// reveals the project on the local host (no-op for remote paths).
    /// Configure / Uninstall stay on the sidebar context menu.
    private var headerActions: some View {
        HStack(spacing: 6) {
            Button {
                Task { await viewModel?.load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh this project")
            .accessibilityLabel(Text("Refresh this project"))

            Button {
                serverContext.openInLocalEditor(project.path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel(Text("Reveal in Finder"))
            .disabled(serverContext.isRemote)

            Button {
                showDoctor = true
            } label: {
                Image(systemName: "stethoscope")
            }
            .buttonStyle(.borderless)
            .help("Check your projects for setup problems")
            .accessibilityLabel(Text("Project Doctor"))
        }
    }

    private var modelBadge: some View {
        let name = viewModel?.modelPresetName
        return Label(name.map { "Model: \($0)" } ?? "Model: default", systemImage: "cpu")
            .font(.caption)
            .foregroundStyle(name == nil ? ScarfColor.foregroundMuted : ScarfColor.accentActive)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(name == nil ? Color.clear : ScarfColor.accentTint)
            .clipShape(Capsule())
            .help(name == nil
                ? "No model preset bound — inherits the global default."
                : "Applied at session boot via session/set_model.")
    }

    @ViewBuilder
    private var hostBadges: some View {
        let bindings = viewModel?.scarfProject?.hostBindings ?? []
        ForEach(bindings, id: \.serverId) { binding in
            Label(hostLabel(for: binding.serverId), systemImage: "server.rack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ScarfColor.backgroundTertiary)
                .clipShape(Capsule())
                .help("This project is materialized on this host.")
        }
    }

    /// "Local" for the well-known local server id; a short id prefix
    /// otherwise. (Full fleet/portfolio naming arrives with multi-host
    /// materialization in a later phase.)
    private func hostLabel(for serverId: String) -> String {
        if serverId == ServerContext.local.id.uuidString { return "Local" }
        if serverId == serverContext.id.uuidString { return serverContext.displayName }
        return String(serverId.prefix(8))
    }

    // MARK: - Upgrade banner

    /// Shown on a project that hasn't had the first-class upgrade pass.
    /// One click runs the deterministic structure pass, then hands off to
    /// chat where the agent enriches the project (dashboard, slash, cron,
    /// a starter mini-app).
    private var upgradeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(ScarfColor.accentActive)
            VStack(alignment: .leading, spacing: 1) {
                Text("Upgrade this project")
                    .font(.callout.weight(.medium))
                Text("Get a tailored dashboard, a board, and a starter mini-app — built for this project in chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(coordinator.isUpgrading(project.path) ? "Upgrading…" : "Upgrade") {
                let hasKanban = capabilitiesStore?.capabilities.hasKanban ?? false
                Task { await coordinator.upgradeProject(project, context: serverContext, hasKanban: hasKanban) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(coordinator.isUpgrading(project.path))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScarfColor.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }

    // MARK: - Panel bar

    /// First webview widget across the dashboard's sections, if any — the
    /// Site panel renders it full-canvas (matches the old Site tab).
    private var siteWidget: DashboardWidget? {
        viewModel?.dashboard?.sections.flatMap(\.widgets).first { $0.type == "webview" }
    }

    private var visiblePanels: [CockpitPanel] {
        let hasKanban = capabilitiesStore?.capabilities.hasKanban ?? false
        let hasDashboard = viewModel?.dashboard != nil
        let hasSite = siteWidget != nil
        let hasProjectTrust = capabilitiesStore?.capabilities.hasSkillsProjectTrust ?? false
        return CockpitPanel.allCases.filter { panel in
            switch panel {
            case .dashboard: return hasDashboard   // hidden for dashboard-less projects
            case .board:     return hasKanban
            case .site:      return hasSite        // hidden without a webview widget
            case .skills:    return hasProjectTrust // v0.20.4 repo-local skills + trust
            default:         return true
            }
        }
    }

    private var panelBar: some View {
        HStack(spacing: 0) {
            ForEach(visiblePanels, id: \.self) { panel in
                Button {
                    selectedPanel = panel
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: panel.systemImage)
                            .font(.caption)
                        Text(panel.title)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedPanel == panel ? ScarfColor.accentTint : Color.clear)
                    .foregroundStyle(selectedPanel == panel ? ScarfColor.accentActive : ScarfColor.foregroundMuted)
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
                }
                .buttonStyle(.plain)
                // The active tab is tinted and nothing else; without the
                // trait VoiceOver cannot tell which panel is showing.
                .accessibilityAddTraits(selectedPanel == panel ? [.isSelected] : [])
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Project panels"))
    }

    // MARK: - Panel content

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel {
        case .dashboard:
            // The legacy `.scarf/dashboard.json` widgets — now a panel so
            // the cockpit is the single project pane (gated above on the
            // project actually having a dashboard).
            CockpitDashboardPanel(
                dashboard: viewModel?.dashboard,
                projectRoot: project.path,
                isLoading: viewModel?.isLoading ?? true
            )
        case .sessions:
            // Reuse the existing per-project Sessions view verbatim.
            ProjectSessionsView(project: project)
        case .board:
            // Reuse the existing per-project Kanban tab (gated above).
            ProjectKanbanTab(project: project)
        case .site:
            // Full-canvas webview widget (matches the old Site tab).
            if let widget = siteWidget {
                WebviewWidgetView(widget: widget, fullCanvas: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CockpitEmptyState(icon: "globe", text: "No site widget in this project's dashboard.")
            }
        case .context:
            CockpitContextPanel(block: viewModel?.contextBlock, isLoading: viewModel?.isLoading ?? true)
        case .cron:
            CockpitCronPanel(jobs: viewModel?.cronJobs ?? [], isLoading: viewModel?.isLoading ?? true)
        case .memory:
            CockpitMemoryPanel(
                namespace: viewModel?.scarfProject?.memoryNamespace,
                block: viewModel?.memoryBlock
            )
        case .secrets:
            CockpitSecretsPanel(names: viewModel?.scarfProject?.secretsScope ?? [])
        case .skills:
            CockpitProjectSkillsPanel(projectRoot: project.path)
        case .templates:
            CockpitTemplatesPanel(
                templateID: viewModel?.templateID,
                templateVersion: viewModel?.templateVersion,
                lockRef: viewModel?.scarfProject?.templateLockRef
            )
        case .slash:
            // Retained from the old tab bar — reuse the existing view.
            ProjectSlashCommandsView(project: project)
        case .miniapps:
            CockpitMiniAppsPanel(
                project: viewModel?.scarfProject,
                manifests: viewModel?.miniApps ?? [],
                serverContext: serverContext,
                onOpen: { manifest in
                    if let scarfProject = viewModel?.scarfProject {
                        coordinator.presentedMiniApp = .init(project: scarfProject, manifest: manifest)
                    }
                }
            )
        case .fleet:
            CockpitFleetPanel(
                sourceProject: viewModel?.scarfProject,
                currentContext: serverContext,
                contexts: serverRegistry.allContexts
            )
        }
    }
}

// MARK: - Panel identity

private enum CockpitPanel: String, CaseIterable {
    case dashboard, sessions, board, site, context, cron, memory, secrets, skills, templates, slash, miniapps, fleet

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .sessions:  return "Sessions"
        case .board:     return "Board"
        case .site:      return "Site"
        case .context:   return "Context"
        case .cron:      return "Cron"
        case .memory:    return "Memory"
        case .secrets:   return "Secrets"
        case .skills:    return "Skills"
        case .templates: return "Templates"
        case .slash:     return "Slash"
        case .miniapps:  return "Mini-apps"
        case .fleet:     return "Fleet"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .sessions:  return "bubble.left.and.bubble.right"
        case .board:     return "rectangle.split.3x1"
        case .site:      return "globe"
        case .context:   return "doc.text"
        case .cron:      return "clock"
        case .memory:    return "brain"
        case .secrets:   return "key"
        case .skills:    return "sparkles"
        case .templates: return "shippingbox"
        case .slash:     return "slash.circle"
        case .miniapps:  return "macwindow"
        case .fleet:     return "square.stack.3d.up"
        }
    }
}

// MARK: - Lightweight panels

/// The project's `dashboard.json` widgets — the legacy dashboard, now a
/// cockpit panel so the cockpit is the single project pane. Renders the
/// same `DashboardSectionView`s the old Dashboard tab did, with the
/// project root in scope for file-reading widgets (markdown_file, etc.).
private struct CockpitDashboardPanel: View {
    let dashboard: ProjectDashboard?
    let projectRoot: String
    let isLoading: Bool

    /// ONE stat per tick for every file-reading widget below, instead of one
    /// per widget — see `WidgetSignatureBatch`. Lives here because this is
    /// the view that knows the whole widget set.
    @State private var signatureBatch = WidgetSignatureBatch()

    private var widgetFilePaths: [String] {
        WidgetSignatureBatch.filePaths(in: dashboard, projectRoot: projectRoot)
    }

    var body: some View {
        Group {
            if let dashboard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(dashboard.sections) { section in
                            DashboardSectionView(section: section)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .environment(\.selectedProjectRoot, projectRoot)
                .environment(
                    \.widgetSignatureScope,
                    WidgetSignatureScope(batch: signatureBatch, paths: widgetFilePaths)
                )
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CockpitEmptyState(
                    icon: "square.grid.2x2",
                    text: "This project has no dashboard. Add a .scarf/dashboard.json to define widgets."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Read-only preview of the Scarf-managed AGENTS.md block — the
/// projection of the `ScarfProject` the agent actually sees.
private struct CockpitContextPanel: View {
    let block: String?
    let isLoading: Bool

    var body: some View {
        Group {
            if let block, !block.isEmpty {
                ScrollView {
                    Text(block)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CockpitEmptyState(
                    icon: "doc.text",
                    text: "No Scarf-managed AGENTS.md block yet. It's written on the next project-scoped chat."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Cron jobs attributed to this project (`[proj:<id>]` / `[tmpl:<id>]`).
private struct CockpitCronPanel: View {
    let jobs: [HermesCronJob]
    let isLoading: Bool

    var body: some View {
        Group {
            if !jobs.isEmpty {
                List(jobs) { job in
                    HStack(spacing: 10) {
                        Image(systemName: job.enabled ? "clock.fill" : "pause.circle")
                            .foregroundStyle(job.enabled ? ScarfColor.success : ScarfColor.foregroundMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name).font(.callout).lineLimit(1)
                            Text(scheduleText(job))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(job.enabled ? "enabled" : "paused")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CockpitEmptyState(
                    icon: "clock",
                    text: "No cron jobs attributed to this project."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleText(_ job: HermesCronJob) -> String {
        job.schedule.display ?? job.schedule.expression ?? job.schedule.kind
    }
}

/// The project's MEMORY.md block, when it owns one.
private struct CockpitMemoryPanel: View {
    let namespace: String?
    let block: String?

    var body: some View {
        Group {
            if let block, !block.isEmpty {
                ScrollView {
                    Text(block)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if let namespace {
                CockpitEmptyState(
                    icon: "brain",
                    text: "Memory namespace `\(namespace)` is bound, but no matching block was found in MEMORY.md."
                )
            } else {
                CockpitEmptyState(
                    icon: "brain",
                    text: "This project has no memory block."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Secret field NAMES only — values stay in the Keychain (SECRET-SAFE).
private struct CockpitSecretsPanel: View {
    let names: [String]

    var body: some View {
        Group {
            if !names.isEmpty {
                List(names, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(ScarfColor.warning)
                        Text(name).font(.callout.monospaced())
                        Spacer()
                        Text("Keychain — name only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            } else {
                CockpitEmptyState(
                    icon: "key",
                    text: "This project declares no secret configuration fields."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Installed-template id/version + the uninstall lock reference.
private struct CockpitTemplatesPanel: View {
    let templateID: String?
    let templateVersion: String?
    let lockRef: String?

    var body: some View {
        Group {
            if let templateID {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Template") {
                        Text("\(templateID)\(templateVersion.map { " v\($0)" } ?? "")")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    if let lockRef {
                        LabeledContent("Uninstall manifest") {
                            Text(lockRef)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                CockpitEmptyState(
                    icon: "shippingbox",
                    text: "This project wasn't installed from a template."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared empty-state for the lightweight panels.
/// Repo-local ("project") skills — Hermes v0.20.4. A checkout can carry
/// skills under `./.hermes/skills` or `./.agents/skills`, but Hermes
/// only loads them once the repo root is trusted. The panel shows what's
/// on disk plus the trust toggle, which shells out to
/// `hermes skills trust|untrust <path>`.
///
/// Gated on `hasSkillsProjectTrust` at the panel bar, so it never
/// appears on hosts without the verbs.
private struct CockpitProjectSkillsPanel: View {
    let projectRoot: String

    @Environment(\.serverContext) private var serverContext
    @State private var viewModel: ProjectSkillsViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trustBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: projectRoot) {
            let vm = ProjectSkillsViewModel(context: serverContext, projectRoot: projectRoot)
            viewModel = vm
            await vm.load()
        }
    }

    @ViewBuilder
    private var trustBar: some View {
        if let vm = viewModel {
            HStack(spacing: 10) {
                Image(systemName: vm.isTrusted ? "checkmark.seal.fill" : "hand.raised.slash")
                    .foregroundStyle(vm.isTrusted ? ScarfColor.success : ScarfColor.foregroundMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.isTrusted ? "Trusted for project skills" : "Not trusted")
                        .font(.callout.weight(.medium))
                    Text(vm.isTrusted
                        ? "Skills in this repo load for sessions started here, ahead of same-named profile skills."
                        : "Skills in this repo are ignored until you trust it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.isTrusted {
                    Button("Untrust") { vm.setTrusted(false) }
                        .controlSize(.small)
                        .disabled(vm.isBusy)
                } else {
                    Button("Trust Repo") { vm.setTrusted(true) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isBusy)
                }
            }
            .padding(10)
            if let message = vm.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel, !vm.skills.isEmpty {
            List(vm.skills) { skill in
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(vm.isTrusted ? ScarfColor.accentActive : ScarfColor.foregroundMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(.callout)
                        Text(skill.source)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !vm.isTrusted {
                        Text("inactive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)
        } else if viewModel?.isLoading ?? true {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CockpitEmptyState(
                icon: "sparkles",
                text: "No repo-local skills. Add them under \(ProjectSkillsScanner.subdirectories.joined(separator: " or "))."
            )
        }
    }
}

struct CockpitEmptyState: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
