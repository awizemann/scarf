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

    /// Last reconciliation pass, driving the cockpit's health row. `nil`
    /// until the first pass finishes.
    ///
    /// Deliberately NOT refreshed on every load: the doctor lists
    /// directories and re-reads the registry, and this view model reloads
    /// from `.onChange(fileWatcher.lastChangeDate)`, which fires per
    /// persisted message during a stream. On an SSH context that would put a
    /// directory crawl behind every token. It runs at most once per cache
    /// window (see `ProjectHealthCache`) and whenever a caller explicitly
    /// asks (`recheckHealth`) — after the doctor sheet closes, that is.
    var health: ProjectDoctorReport?

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

    func load(force: Bool = false, recheckHealth: Bool = false) async {
        if recheckHealth { ProjectHealthCache.shared.invalidate(context.id) }
        if hasLoaded && !force && !recheckHealth { return }
        if let existing = inFlightLoad {
            await existing.value
            // A recheck that merely JOINED an in-flight pass has not been
            // served: that pass decided whether to scan before the
            // invalidation above. Run our own so the health row actually
            // reflects the repairs the user just made.
            if recheckHealth, ProjectHealthCache.shared.report(context.id) == nil {
                await loadImpl()
            }
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
        // Claimed before the detached work starts, so two loads that overlap
        // (a watcher tick landing on the first open) don't both scan. The
        // claim lives in a per-CONTEXT cache rather than on this instance:
        // the cockpit builds a new view model per project, so an
        // instance-scoped flag re-ran a registry-wide scan on every project
        // switch — and again on every switch back.
        let cached = ProjectHealthCache.shared.report(context.id)
        let shouldDiagnose = ProjectHealthCache.shared.claimIfIdle(context.id)

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
                do {
                    try store.save(derived)
                } catch {
                    // Still best-effort — the in-memory record is usable and
                    // the cockpit must open — but no longer SILENT. Since the
                    // registry write refuses a lossy `projects.json` from
                    // inside `saveRegistry`, this is the path a damaged
                    // registry now takes: opening a project simply doesn't
                    // migrate it, where before it would have written the
                    // salvaged short list back over the file. That is a thing
                    // worth finding in a log.
                    Logger(subsystem: "com.scarf", category: "ProjectCockpitViewModel").warning(
                        "cockpit couldn't persist derived record for \(project.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
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
            let health = shouldDiagnose ? ProjectDoctorService(context: context).diagnose() : nil

            return Loaded(
                project: sp,
                block: block,
                jobs: jobs,
                memory: memory,
                templateID: tmpl?.id,
                templateVersion: tmpl?.version,
                miniApps: miniApps,
                dashboard: dashboard,
                needsUpgrade: needsUpgrade,
                health: health
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
        if let fresh = result.health {
            ProjectHealthCache.shared.store(fresh, for: context.id)
            health = fresh
        } else {
            // A load that skipped the scan reuses the cached verdict rather
            // than blanking the health row.
            health = cached ?? health
        }
        isLoading = false

        // Resolve the bound preset's display name (actor hop), if any.
        if let presetID = result.project.modelPresetId, let uuid = UUID(uuidString: presetID) {
            modelPresetName = (try? await ModelPresetService.shared(for: context).get(id: uuid))?.name
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
        /// `nil` when this pass deliberately skipped the reconciliation scan.
        let health: ProjectDoctorReport?
    }
}
