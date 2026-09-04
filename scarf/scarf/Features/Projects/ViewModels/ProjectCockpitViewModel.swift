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

    /// `path -> "<mtime-seconds>:<size>"` for every file the last committed
    /// load actually read. A load whose signature matches this one has
    /// nothing to do: same bytes in, same values out.
    ///
    /// Paired with SIZE rather than mtime alone — one-second granularity is
    /// what `stat` reports over SSH, so mtime alone calls two writes in the
    /// same second identical. It is a cheap check, not a hash: a
    /// same-second, same-size rewrite is still missed until the next change.
    /// The alternative (reading every facet to find out) is the ~10
    /// round-trips per tick this exists to remove.
    @ObservationIgnored private var lastFacetSignature: [String: String]?

    /// Mini-app manifest paths the last load discovered — folded into the
    /// signature so an edit to an EXISTING `miniapp.json` is seen (the
    /// `miniapps/` dir mtime only ticks on add/remove/rename).
    @ObservationIgnored private var lastMiniAppManifestPaths: [String] = []

    /// Test seam: how many times the full facet read has actually run. A
    /// tick that short-circuits must not move it.
    @ObservationIgnored private(set) var facetLoadCount = 0

    /// Why this load is running. The distinction the doctor cares about:
    /// a scan is ~110 transport ops and must never hang off a file-watcher
    /// tick, however stale the cache window says the verdict is.
    enum LoadReason {
        /// The user opened this project, or explicitly asked for a refresh.
        case userInitiated
        /// A watcher tick. Short-circuits on an unchanged signature and
        /// NEVER runs the doctor.
        case watcher
    }

    func load(
        force: Bool = false,
        recheckHealth: Bool = false,
        reason: LoadReason = .userInitiated
    ) async {
        if recheckHealth { ProjectHealthCache.shared.invalidate(context.id) }
        if hasLoaded && !force && !recheckHealth { return }
        if let existing = inFlightLoad {
            await existing.value
            // A recheck that merely JOINED an in-flight pass has not been
            // served: that pass decided whether to scan before the
            // invalidation above. Run our own so the health row actually
            // reflects the repairs the user just made.
            if recheckHealth, ProjectHealthCache.shared.report(context.id) == nil {
                await loadImpl(reason: .userInitiated, recheckHealth: true)
            }
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.loadImpl(reason: reason, recheckHealth: recheckHealth)
        }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
    }

    /// Every file a full load reads, in the order the load reads them.
    /// Handed to `transport.statAll` as ONE batched round-trip.
    private func facetPaths() -> [String] {
        let root = project.path
        return [
            ProjectStore.recordPath(forProjectPath: root),
            root + "/AGENTS.md",
            root + "/.scarf/manifest.json",
            root + "/.scarf/dashboard.json",
            root + "/.scarf/upgrade.json",
            MiniAppService.miniAppsDir(forProjectPath: root),
            context.paths.cronJobsJSON,
            context.paths.memoryMD
        ] + lastMiniAppManifestPaths
    }

    /// `nil` when the batched stat could not be trusted (see
    /// `ServerTransport.statAll`). Deliberately NOT "every path absent":
    /// that map is a lie about the filesystem, it never matches the
    /// previous signature, and it therefore drove a full facet reload —
    /// including the derive-and-save of a project record — over exactly
    /// the transport that had just failed to answer a single `stat`.
    /// That is the stripped-record shape D3 closed, re-entered through
    /// the fast path.
    private nonisolated static func signature(
        of paths: [String], transport: any ServerTransport
    ) -> [String: String]? {
        guard let stats = transport.statAll(paths) else { return nil }
        var out: [String: String] = [:]
        for path in paths {
            guard let info = stats[path] else {
                // ABSENT is a state, and it has to be a DIFFERENT state from
                // "present and empty" — otherwise a file appearing would not
                // register as a change.
                out[path] = "-"
                continue
            }
            out[path] = "\(Int(info.mtime.timeIntervalSince1970)):\(info.size)"
        }
        return out
    }

    /// The tick short-circuit decision, as a pure function of what we
    /// asked and what the transport managed to tell us.
    ///
    /// Three outcomes, and the middle one is the fix: a signature that
    /// MATCHES means nothing changed (skip); a signature that DIFFERS
    /// means read; and NO signature at all — `statAll` refusing to
    /// vouch for its own answer — means we learned nothing, which is not
    /// the same as learning that everything changed. The old code
    /// fabricated an all-absent map for that case, guaranteeing a
    /// mismatch and sending a full facet reload (record derive + save
    /// included) over the transport that had just failed.
    static func shouldRead(
        reason: LoadReason,
        recheckHealth: Bool,
        fresh: [String: String]?,
        last: [String: String]?
    ) -> Bool {
        guard reason == .watcher, !recheckHealth else { return true }
        guard let fresh else { return false }
        return fresh != last
    }

    private func loadImpl(reason: LoadReason, recheckHealth: Bool) async {
        // FAST PATH. One batched stat answers "did any input change?"; when
        // nothing did, this pass reads nothing and — just as importantly —
        // writes nothing to @Observable state, so SwiftUI does not
        // re-evaluate every cockpit panel per tick.
        //
        // Deliberately NOT taken for a user-initiated pass: the signature
        // covers the files, and a user asking for a refresh may be asking
        // about something it doesn't (a model preset rename, a doctor
        // verdict). Ticks are the hot path and the only one this needs.
        let paths = facetPaths()
        let signatureContext = context
        let freshSignature = await Task.detached(priority: .utility) {
            Self.signature(of: paths, transport: signatureContext.makeTransport())
        }.value
        guard Self.shouldRead(
            reason: reason,
            recheckHealth: recheckHealth,
            fresh: freshSignature,
            last: lastFacetSignature
        ) else { return }
        // Captured BEFORE the reads below, so a write that lands while they
        // are in flight is seen by the next pass rather than assumed into
        // the record. An untrusted stat leaves the PREVIOUS signature in
        // place rather than clearing it: the user-initiated load below is
        // running regardless, and a nil baseline would only buy a
        // guaranteed extra reload on the next tick.
        if let freshSignature { lastFacetSignature = freshSignature }
        facetLoadCount += 1
        hasLoaded = true
        isLoading = true
        // Claimed before the detached work starts, so two loads that overlap
        // (a watcher tick landing on the first open) don't both scan. The
        // claim lives in a per-CONTEXT cache rather than on this instance:
        // the cockpit builds a new view model per project, so an
        // instance-scoped flag re-ran a registry-wide scan on every project
        // switch — and again on every switch back.
        let cached = ProjectHealthCache.shared.report(context.id)
        // NEVER OFF A TICK. The doctor lists directories and re-reads the
        // registry — ~110 transport ops on a 20-project host — and this
        // view model reloads from `.onChange(fileWatcher.lastChangeDate)`,
        // which fires per persisted message during a stream. The class doc
        // has said "not on every load" since it was written; the cache
        // window was doing the enforcing, which meant that every five
        // minutes a watcher tick DID pay for a full crawl. The reason, not
        // the clock, decides now: a user opening the project or asking for
        // a recheck scans (subject to the cache window); a tick never does.
        let shouldDiagnose = reason == .userInitiated
            && ProjectHealthCache.shared.claimIfIdle(context.id)

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
        // Fold the discovered manifests into the NEXT signature: the
        // `miniapps/` directory mtime only ticks on add/remove/rename, so
        // without these an edit to an installed mini-app's manifest would
        // sit behind the short-circuit indefinitely.
        lastMiniAppManifestPaths = result.miniApps.map {
            MiniAppService.manifestPath(forProjectPath: project.path, id: $0.id)
        }
        // TOP UP THE SIGNATURE FOR THE PATHS WE ONLY JUST LEARNED ABOUT.
        // The signature committed above was taken over `facetPaths()` as it
        // stood BEFORE this load, which by definition did not include the
        // manifests this load just discovered. The next tick's signature
        // does include them, so the two maps could never match and every
        // discovery bought exactly one guaranteed extra full reload — on
        // first open of every project with mini-apps, and again whenever one
        // is added. Stat only the new paths and fold them in; an untrusted
        // stat just leaves the old behaviour (one extra reload) in place.
        let newPaths = lastMiniAppManifestPaths.filter { lastFacetSignature?[$0] == nil }
        if !newPaths.isEmpty, lastFacetSignature != nil {
            let topUpContext = context
            let extra = await Task.detached(priority: .utility) {
                Self.signature(of: newPaths, transport: topUpContext.makeTransport())
            }.value
            if let extra {
                for (path, value) in extra { lastFacetSignature?[path] = value }
            }
        }
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
