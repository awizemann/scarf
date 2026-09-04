import Foundation
import ScarfCore
import os

/// Backs `ProjectCockpitView` — the per-project "mission control" that
/// aggregates every facet of a `ScarfProject` into one destination.
///
/// Loads the first-class record (`ProjectStore.load`), deriving + lazily
/// persisting it on first open if the project predates Phase 1 (additive,
/// non-fatal migration), then resolves the read-only projections the
/// lightweight panels render: the AGENTS.md managed block, project-scoped
/// cron jobs, the MEMORY.md block, and the installed-template id/version.
///
/// All disk I/O runs in one off-main `Task.detached`; the `@MainActor`
/// `@Observable` properties are written back on the main actor. Mirrors
/// the load shape of `CronViewModel` / `ProjectSessionsViewModel`.
@Observable
@MainActor
final class ProjectCockpitViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProjectCockpitViewModel")

    let context: ServerContext
    let project: ProjectEntry

    /// The canonical (or freshly-derived) record — source of truth for
    /// the header + Secrets/Templates panels.
    var scarfProject: ScarfProject?
    /// The project's `dashboard.json` widgets, when present — rendered in
    /// the Dashboard panel. `nil` for a project without a dashboard (the
    /// panel is then hidden). Loaded alongside the other facets so the
    /// cockpit is a self-contained project pane.
    var dashboard: ProjectDashboard?
    /// Resolved display name of the bound model preset, or `nil` when
    /// none is bound / it no longer resolves.
    var modelPresetName: String?
    /// The Scarf-managed AGENTS.md block (inclusive of markers), for the
    /// read-only Context panel.
    var contextBlock: String?
    /// Cron jobs attributed to this project (`[proj:<id>]` or `[tmpl:]`).
    var cronJobs: [HermesCronJob] = []
    /// The project's MEMORY.md block, when it owns one.
    var memoryBlock: String?
    /// Installed-template id + version for the Templates panel.
    var templateID: String?
    var templateVersion: String?
    /// Discovered mini-apps for the Mini-apps panel.
    var miniApps: [MiniAppManifest] = []
    /// Whether the project still needs the deterministic upgrade pass —
    /// drives the cockpit's "Upgrade available" banner.
    var needsUpgrade = false
    var isLoading = false

    @ObservationIgnored private var hasLoaded = false

    init(context: ServerContext, project: ProjectEntry) {
        self.context = context
        self.project = project
    }

    /// Single in-flight load handle. The cockpit reloads from
    /// `.onChange(fileWatcher.lastChangeDate)`, which fires per persisted
    /// message during an active stream — far faster than this load (a project
    /// store read, an AGENTS.md read and a full cron-jobs read) completes.
    /// Overlapping passes committed in completion order rather than issue
    /// order. `force` only decides whether to SKIP, never what gets loaded,
    /// so joining an in-flight pass is correct for `force: true` too — an
    /// in-flight load is already a fresh one.
    @ObservationIgnored private var inFlightLoad: Task<Void, Never>?

    func load(force: Bool = false) async {
        if hasLoaded && !force { return }
        if let existing = inFlightLoad {
            await existing.value
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.loadImpl()
        }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
    }

    private func loadImpl() async {
        hasLoaded = true
        isLoading = true

        let context = self.context
        let project = self.project

        let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
            let store = ProjectStore(context: context)
            // Load-or-derive. A freshly-derived record is persisted so
            // opening the cockpit lazily migrates this project to the
            // first-class model. Best-effort — a write failure leaves
            // the in-memory record usable.
            let sp: ScarfProject
            if let loaded = store.load(projectPath: project.path) {
                sp = loaded
            } else {
                let derived = store.derive(from: project)
                try? store.save(derived)
                sp = derived
            }

            // Context: the AGENTS.md managed block (read-only preview).
            let agents = context.readText(project.path + "/AGENTS.md")
            let block = Self.extractBlock(
                agents,
                begin: ProjectContextBlock.beginMarker,
                end: ProjectContextBlock.endMarker
            )

            // Cron: jobs tagged for this project.
            let tmpl = Self.readTemplateInfo(context: context, projectPath: project.path)
            let allJobs = HermesFileService(context: context).loadCronJobs()
            let projPrefix = "[proj:\(sp.id.uuidString)]"
            let tmplPrefix = tmpl.map { "[tmpl:\($0.id)]" }
            let jobs = allJobs.filter { job in
                if job.name.hasPrefix(projPrefix) { return true }
                if let tmplPrefix, job.name.hasPrefix(tmplPrefix) { return true }
                return false
            }

            // Memory: the project's MEMORY.md block, when it owns one.
            var memory: String?
            if let ns = sp.memoryNamespace {
                let memText = context.readText(context.paths.memoryMD)
                memory = Self.extractBlock(
                    memText,
                    begin: "<!-- scarf-template:\(ns):begin -->",
                    end: "<!-- scarf-template:\(ns):end -->"
                )
            }

            let miniApps = MiniAppService(context: context).discover(projectPath: project.path)

            // Dashboard: the legacy `.scarf/dashboard.json` widgets, now a
            // cockpit panel (the cockpit is the single project pane). `nil`
            // when the project ships no dashboard — the panel is hidden.
            let dashboard = ProjectDashboardService(context: context).loadDashboard(for: project)
            let needsUpgrade = ProjectUpgradeService(context: context).needsUpgrade(project)

            return Loaded(
                project: sp,
                block: block,
                jobs: jobs,
                memory: memory,
                templateID: tmpl?.id,
                templateVersion: tmpl?.version,
                miniApps: miniApps,
                dashboard: dashboard,
                needsUpgrade: needsUpgrade
            )
        }.value

        scarfProject = result.project
        contextBlock = result.block
        cronJobs = result.jobs
        memoryBlock = result.memory
        templateID = result.templateID
        templateVersion = result.templateVersion
        miniApps = result.miniApps
        dashboard = result.dashboard
        needsUpgrade = result.needsUpgrade
        isLoading = false

        // Resolve the bound preset's display name (actor hop), if any.
        if let presetID = result.project.modelPresetId, let uuid = UUID(uuidString: presetID) {
            modelPresetName = (try? await ModelPresetService(context: context).get(id: uuid))?.name
        } else {
            modelPresetName = nil
        }
    }

    // MARK: - Pure helpers

    /// Slice out `[begin … end]` inclusive from `text`, or `nil` when
    /// either marker is absent. Used for both the AGENTS.md and MEMORY.md
    /// managed blocks.
    nonisolated static func extractBlock(_ text: String?, begin: String, end: String) -> String? {
        guard let text,
              let b = text.range(of: begin),
              let e = text.range(of: end, range: b.upperBound..<text.endIndex)
        else {
            return nil
        }
        return String(text[b.lowerBound..<e.upperBound])
    }

    /// `(id, version)` from `<project>/.scarf/manifest.json`, suppressing
    /// the `KanbanTenantResolver` sentinel. Forwards to `ProjectStore` so
    /// the sentinel rule has exactly one implementation.
    nonisolated static func readTemplateInfo(
        context: ServerContext,
        projectPath: String
    ) -> (id: String, version: String)? {
        ProjectStore(context: context).templateInfo(projectPath: projectPath)
    }

    private struct Loaded: Sendable {
        let project: ScarfProject
        let block: String?
        let jobs: [HermesCronJob]
        let memory: String?
        let templateID: String?
        let templateVersion: String?
        let miniApps: [MiniAppManifest]
        let dashboard: ProjectDashboard?
        let needsUpgrade: Bool
    }
}
