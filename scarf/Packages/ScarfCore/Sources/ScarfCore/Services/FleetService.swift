import Foundation
import Dispatch
#if canImport(os)
import os
#endif

/// The fleet/portfolio reader — gathers `ScarfProject`s across every
/// server the user has registered and groups them by stable id into a
/// `ProjectPortfolio` (Phase-1 item #4, the "Fleet dimension").
///
/// **Read-only.** `portfolio()` runs `ProjectStore.list()` per context
/// (which derives missing records on the fly but does NOT persist), then
/// hands the per-host lists to the pure `ProjectPortfolio.build(from:)`
/// grouper. Nothing is written; the disk/SFTP reads mean callers must run
/// it off the main actor.
///
/// **Why contexts are injected, not discovered.** The list of servers
/// lives in the Mac app target's `ServerRegistry` (`servers.json`), which
/// ScarfCore can't see. The caller passes `registry.allContexts` in; this
/// keeps `FleetService` a pure, transport-driven ScarfCore service that
/// iterates whatever hosts it's given — and trivially unit-testable
/// against a couple of temp-home `.local` contexts.
public struct FleetService: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "FleetService")
    #endif

    /// The servers to gather across. Order is preserved into per-host
    /// gather order; the portfolio itself re-sorts for display.
    public let contexts: [ServerContext]

    public nonisolated init(contexts: [ServerContext]) {
        self.contexts = contexts
    }

    // MARK: - Gather

    /// Gather every host's projects and group them into the portfolio.
    /// Disk/SFTP I/O — call off-main. A host whose registry can't be read
    /// contributes an empty list rather than failing the whole gather
    /// (NON-FATAL: one unreachable remote never blanks the fleet view).
    /// Multiple hosts are gathered CONCURRENTLY (see below).
    public nonisolated func portfolio() -> ProjectPortfolio {
        // The per-host walks are independent — each builds its own registry +
        // transport and shares no mutable state — so for multiple servers we
        // run them concurrently. Serially the cost is the SUM of per-host
        // latency (and for remotes each host is a batch of blocking SFTP
        // reads); concurrent gather collapses it toward the slowest single
        // host. `portfolio()` is call-off-main, so blocking GCD worker
        // threads is fine, and `build(from:)` is a pure, order-independent
        // grouper (it re-sorts for display).
        let contexts = self.contexts
        let hosts: [ProjectPortfolio.HostProjects]
        if contexts.count <= 1 {
            hosts = contexts.map(gather)          // single host (the norm) — no fan-out
        } else {
            let collector = HostCollector(count: contexts.count)
            DispatchQueue.concurrentPerform(iterations: contexts.count) { i in
                collector.set(i, gather(contexts[i]))
            }
            hosts = collector.ordered()
        }
        return ProjectPortfolio.build(from: hosts)
    }

    /// Gather one host's stably-identified projects into a `HostProjects`.
    private nonisolated func gather(_ ctx: ServerContext) -> ProjectPortfolio.HostProjects {
        ProjectPortfolio.HostProjects(
            serverId: ctx.id.uuidString,
            serverDisplayName: ctx.displayName,
            projects: stablyIdentifiedProjects(on: ctx)
        )
    }

    /// Every project on `ctx` that carries a **stable** id — the canonical
    /// `.scarf/project.json` record when present, else a derive from a
    /// registry row that already holds a `uuid`.
    ///
    /// **Why not `ProjectStore.list()`.** `list()` falls back to
    /// `derive(from:)`, whose id for a row with neither a record nor a uuid
    /// is derived from the project's `(host, path)` pair. That is stable
    /// across reloads (it no longer mints a fresh random `UUID` — the
    /// transient-id trap M1 warned about) and cannot collide across hosts
    /// (`ProjectIdentity.hostKey` salts it), but it is still not an identity
    /// CLAIM — nobody asserted it, and the migration may not have run. So the
    /// fleet gather stays stricter than `list()`: it **skips** rows with
    /// neither a record nor a uuid, rather than surfacing a project whose id
    /// is provisional.
    /// Those rows acquire one through normal migration (opening the
    /// project / cockpit, or the per-host eager `derive()` pass) and then
    /// appear in the fleet. Read-only — never persists.
    private nonisolated func stablyIdentifiedProjects(on ctx: ServerContext) -> [ScarfProject] {
        let store = ProjectStore(context: ctx)
        let registry = ProjectDashboardService(context: ctx).loadRegistry()
        return registry.projects.compactMap { entry in
            if let record = store.load(projectPath: entry.path) { return record }
            if entry.uuid != nil { return store.derive(from: entry) }
            return nil
        }
    }

    /// Scoped lookup for the per-project cockpit Fleet panel: the fleet
    /// entry for one stable id across the registered servers, or `nil`
    /// when the id isn't live anywhere (shouldn't happen for a project
    /// the user is actively viewing, but the gather is best-effort).
    /// Disk/SFTP I/O — call off-main.
    public nonisolated func fleetProject(id: UUID) -> FleetProject? {
        portfolio().project(id: id)
    }
}

/// Lock-guarded, index-addressed sink for the concurrent per-host gather in
/// `FleetService.portfolio()`: each `concurrentPerform` iteration writes its
/// own slot, then `ordered()` returns them in context order (dropping any that
/// somehow stayed nil). `@unchecked Sendable` — the only mutable state is
/// behind the lock.
private final class HostCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [ProjectPortfolio.HostProjects?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: ProjectPortfolio.HostProjects) {
        lock.lock(); slots[index] = value; lock.unlock()
    }
    func ordered() -> [ProjectPortfolio.HostProjects] {
        lock.lock(); defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}
