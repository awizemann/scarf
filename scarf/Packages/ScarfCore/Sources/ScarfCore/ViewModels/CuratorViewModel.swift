import Foundation
import Observation
#if canImport(os)
import os
#endif

/// Mac + iOS view model for the Curator surface (v0.12 base + v0.13
/// archive/prune additions).
///
/// Drives `hermes curator status / run / pause / resume / pin / unpin /
/// restore` plus (v0.13+) `archive`, `prune`, `list-archived`. All CLI
/// invocations route through `CuratorService` (the actor) so polling
/// and writes share the same concurrency model and a single error path.
///
/// Capability-gated: callers should construct this only when
/// `HermesCapabilities.hasCurator` is true. Archive-aware UI surfaces
/// (Archive button, Archived section, Prune…) gate independently on
/// `hasCuratorArchive`. The view model itself doesn't gate — it exposes
/// every method and the View decides what to render.
@Observable
@MainActor
public final class CuratorViewModel {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "CuratorViewModel")
    #endif

    public let context: ServerContext

    public private(set) var status: HermesCuratorStatus = .empty
    public private(set) var isLoading = false
    public private(set) var lastReportMarkdown: String?

    // Archive state (v0.13+ only — populated by `loadArchive()` on hosts
    // where `hasCuratorArchive` is true).
    public private(set) var archivedSkills: [HermesCuratorArchivedSkill] = []
    public private(set) var isLoadingArchive = false

    // Unmanaged/adopt state (v0.20+ only — populated by `loadUnmanaged()`
    // on hosts where `hasCuratorAdopt` is true).
    public private(set) var unmanagedSkills: [HermesCuratorUnmanagedSkill] = []
    public private(set) var isAdopting = false

    // Archive-idle ("prune") state — `pruneSummary` non-nil while the confirm
    // sheet is mid-flight; `isPruning` flips during the archive step.
    public private(set) var pruneSummary: CuratorPruneSummary?
    public private(set) var isPruning = false
    /// Idle threshold (days) chosen in `planPrune`, reused by `confirmPrune`.
    private var plannedPruneDays = 90

    // Track which active-skill row is currently being archived so the
    // row chrome can show an inline spinner without blocking the rest.
    public private(set) var pendingArchiveName: String?

    /// Happy-path success toast ("Pinned X", "Resumed", "Archived
    /// legacy-helper"). Auto-clears 3s after assignment.
    public var transientMessage: String?

    /// Failure path — populated by every CLI verb when it throws. Shown
    /// as an inline yellow banner above the status summary so users
    /// don't have to dismiss a modal alert during a high-frequency
    /// surface like the leaderboard. Manually dismissed via the View's
    /// "x" button (sets to nil).
    public var errorMessage: String?

    @ObservationIgnored
    private let service: CuratorService

    public init(context: ServerContext) {
        self.context = context
        self.service = CuratorService(context: context)
    }

    // MARK: - Loads

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let context = self.context
        // v2.8 — instrumented. Curator load fires `hermes curator
        // status` (CLI subprocess) plus 1-2 file reads; on remote each
        // is a separate SSH RTT. Visibility lets future captures show
        // how often the report file is missing or oversized.
        let parsed = await ScarfMon.measureAsync(.diskIO, "curator.load") {
            await Task.detached(priority: .userInitiated) { () -> (HermesCuratorStatus, String?) in
                let textResult = Self.runCuratorStatus(context: context)
                let stateData = context.readData(context.paths.curatorStateFile)
                let parsed = HermesCuratorStatusParser.parse(text: textResult, stateFileJSON: stateData)
                // Best-effort markdown report: the state file points at the
                // most recent <YYYYMMDD-HHMMSS>/ dir; load REPORT.md from
                // there. Missing on first run, which is fine.
                var report: String?
                if let reportDir = parsed.lastReportPath {
                    let reportPath = reportDir.hasSuffix("/")
                        ? "\(reportDir)REPORT.md"
                        : "\(reportDir)/REPORT.md"
                    report = context.readText(reportPath)
                }
                return (parsed, report)
            }.value
        }
        ScarfMon.event(
            .diskIO,
            "curator.load.bytes",
            count: 0,
            bytes: parsed.1?.utf8.count ?? 0
        )
        self.status = parsed.0
        self.lastReportMarkdown = parsed.1
    }

    /// Refresh the archived-skills list. No-op on hosts without
    /// `hasCuratorArchive` — the caller gates the call.
    public func loadArchive() async {
        isLoadingArchive = true
        defer { isLoadingArchive = false }
        do {
            archivedSkills = try await service.listArchived()
        } catch {
            archivedSkills = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Refresh the unmanaged-skills list. No-op on hosts without
    /// `hasCuratorAdopt` — the caller gates the call (mirrors
    /// `loadArchive`).
    public func loadUnmanaged() async {
        do {
            unmanagedSkills = try await service.listUnmanaged()
        } catch {
            unmanagedSkills = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Writes (v0.20 adopt — caller gates on hasCuratorAdopt)

    public func adopt(_ skill: String) async {
        isAdopting = true
        await runWithReload(verb: "adopt", successMessage: "Adopted \(skill)") {
            try await self.service.adopt(name: skill)
        }
        isAdopting = false
        await loadUnmanaged()
    }

    public func adoptAll() async {
        isAdopting = true
        await runWithReload(verb: "adopt", successMessage: "Adopted all unmanaged skills") {
            _ = try await self.service.adoptAll(dryRun: false)
        }
        isAdopting = false
        await loadUnmanaged()
    }

    // MARK: - Writes (v0.12)

    /// Run the curator manually. On v0.13+ hosts this blocks for the
    /// duration of the run (default 600s timeout); pre-v0.13 returns
    /// immediately. Caller passes the capability-decided flag.
    public func runNow(synchronous: Bool, timeout: TimeInterval = 600) async {
        await runWithReload(
            verb: "run",
            successMessage: synchronous ? "Curator run complete" : "Curator run started"
        ) {
            try await self.service.runNow(synchronous: synchronous, timeout: timeout)
        }
    }

    public func pause() async {
        await runWithReload(verb: "pause", successMessage: "Curator paused") {
            try await self.service.pause()
        }
    }

    public func resume() async {
        await runWithReload(verb: "resume", successMessage: "Curator resumed") {
            try await self.service.resume()
        }
    }

    public func pin(_ skill: String) async {
        await runWithReload(verb: "pin", successMessage: "Pinned \(skill)") {
            try await self.service.pin(skill)
        }
    }

    public func unpin(_ skill: String) async {
        await runWithReload(verb: "unpin", successMessage: "Unpinned \(skill)") {
            try await self.service.unpin(skill)
        }
    }

    public func restore(_ skill: String) async {
        await runWithReload(verb: "restore", successMessage: "Restored \(skill)") {
            try await self.service.restore(skill)
        }
        // Restore drops the entry from the archived list — refresh it
        // so the row disappears immediately.
        await loadArchive()
    }

    // MARK: - Writes (v0.13)

    public func archive(_ skill: String) async {
        pendingArchiveName = skill
        await runWithReload(verb: "archive", successMessage: "Archived \(skill)") {
            try await self.service.archive(skill)
        }
        pendingArchiveName = nil
        await loadArchive()
    }

    /// Stage 1 of the archive-idle flow. Calls `curator prune --days N
    /// --dry-run` and populates `pruneSummary` (the idle skills a real run
    /// would archive); the View binds its confirm sheet to the non-nil
    /// presence of this property. `days` is remembered for `confirmPrune`.
    public func planPrune(days: Int = 90) async {
        plannedPruneDays = days
        do {
            pruneSummary = try await service.prune(days: days, dryRun: true)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            pruneSummary = nil
        }
    }

    /// Stage 2 of the archive-idle flow. Bulk-archives the idle skills at the
    /// threshold chosen in `planPrune` (reversible — they remain restorable
    /// from the Archived list). Clears `pruneSummary` regardless of outcome so
    /// the confirm sheet dismisses.
    public func confirmPrune() async {
        isPruning = true
        do {
            _ = try await service.prune(days: plannedPruneDays, dryRun: false)
            transientMessage = "Archived idle skills"
            errorMessage = nil
            await loadArchive()
            await load()
            scheduleTransientClear()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
        isPruning = false
        pruneSummary = nil
    }

    /// Cancel the in-flight prune-confirm flow without running.
    public func cancelPrune() {
        pruneSummary = nil
    }

    /// User-driven dismissal of the inline error banner.
    public func dismissError() {
        errorMessage = nil
    }

    // MARK: - Helpers

    /// Run a service call, route success → `transientMessage`, failure
    /// → `errorMessage`, and reload `status` either way. Mirrors the
    /// previous `runAndReload` helper but goes through the typed
    /// service surface.
    private func runWithReload(
        verb: String,
        successMessage: String,
        body: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await body()
            transientMessage = successMessage
            errorMessage = nil
            await load()
            scheduleTransientClear()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorMessage = message
            transientMessage = nil
            await load()
        }
    }

    private func scheduleTransientClear() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.transientMessage = nil
        }
    }

    // MARK: - Legacy sync helpers (kept for `load`'s detached path)

    nonisolated private static func runHermes(
        context: ServerContext,
        args: [String]
    ) -> (exitCode: Int32, output: String) {
        let transport = context.makeTransport()
        do {
            let result = try transport.runProcess(
                executable: context.paths.hermesBinary,
                args: args,
                stdin: nil,
                timeout: 30
            )
            return (result.exitCode, result.stdoutString + result.stderrString)
        } catch let error as TransportError {
            return (-1, error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    nonisolated private static func runCuratorStatus(context: ServerContext) -> String {
        runHermes(context: context, args: ["curator", "status"]).output
    }
}
