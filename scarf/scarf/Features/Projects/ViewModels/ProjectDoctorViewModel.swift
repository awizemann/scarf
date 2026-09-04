import Foundation
import ScarfCore
import os

/// Backs the Project Doctor sheet: runs `ProjectDoctorService` off-main and
/// commits its report on the main actor.
///
/// Every service call here is synchronous transport I/O — an SSH round-trip
/// per read on a remote context — so `diagnose` and every repair run inside
/// `Task.detached` and only the results come back to the main actor
/// (charter C10). Same shape as `ProjectCockpitViewModel`'s one-off-main-load.
///
/// The doctor is registry-wide rather than per-project: the defects it looks
/// for are relationships BETWEEN projects (duplicates, orphans, rows without
/// folders), which no single project's view can see.
@Observable
@MainActor
final class ProjectDoctorViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProjectDoctorViewModel")

    let context: ServerContext

    private(set) var report: ProjectDoctorReport?
    /// A scan is running. Distinct from `repairingFindingID` so the sheet can
    /// show a scan spinner without disabling a repair that already finished.
    private(set) var isScanning = false
    /// The finding whose repair is in flight, or a sentinel for Repair All.
    private(set) var repairingFindingID: String?
    /// Last repair failure, ready for the sheet's alert.
    private(set) var repairError: String?
    /// Result line after a Repair All pass — how many were fixed, how many
    /// weren't.
    private(set) var repairSummary: String?

    /// Sentinel id used while "Repair All (safe)" runs.
    static let repairAllID = "__repair_all__"

    @ObservationIgnored private var scanGeneration = 0

    init(context: ServerContext) {
        self.context = context
    }

    /// Run (or re-run) the reconciliation pass.
    ///
    /// A newer scan supersedes an older one by generation token: the sheet
    /// re-scans after every repair, and those passes are slower than the taps
    /// that start them, so completion order is not issue order.
    func scan() async {
        scanGeneration &+= 1
        let generation = scanGeneration
        isScanning = true
        let ctx = context
        let fresh = await Task.detached(priority: .userInitiated) {
            ProjectDoctorService(context: ctx).diagnose()
        }.value
        guard generation == scanGeneration else { return }
        report = fresh
        isScanning = false
    }

    /// Apply one finding's repair, then re-scan.
    ///
    /// Serialized against every other repair by `repairingFindingID`: two
    /// concurrent repairs would each load, mutate and save the registry, and
    /// the second save would land on a registry read before the first — a
    /// lost update. The service's writers are idempotent, not atomic across
    /// a read-modify-write pair.
    func repair(_ finding: ProjectDoctorFinding) async {
        guard repairingFindingID == nil else { return }
        repairingFindingID = finding.id
        repairError = nil
        repairSummary = nil
        let ctx = context
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try ProjectDoctorService(context: ctx).repair(finding)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        repairingFindingID = nil
        if let failure {
            repairError = failure
            logger.error("doctor repair \(finding.id, privacy: .public) failed: \(failure, privacy: .public)")
        }
        // Re-scan either way: a partial failure still changed something, and
        // the report in hand no longer describes the disk.
        await scan()
    }

    /// Run every safe repair, then re-scan. Destructive and consent-requiring
    /// repairs (removing a row, adopting an orphan) are never included —
    /// `ProjectDoctorReport.safelyRepairable` decides, not this method.
    func repairAllSafe() async {
        guard let current = report, repairingFindingID == nil else { return }
        let attempted = current.safelyRepairable.count
        guard attempted > 0 else { return }
        repairingFindingID = Self.repairAllID
        repairError = nil
        repairSummary = nil
        let ctx = context
        let failures = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            ProjectDoctorService(context: ctx).repairAllSafe(current)
        }.value
        repairingFindingID = nil
        let fixed = attempted - failures.count
        repairSummary = failures.isEmpty
            ? "Repaired \(fixed) \(fixed == 1 ? "issue" : "issues")."
            : "Repaired \(fixed) of \(attempted); \(failures.count) couldn't be repaired."
        if !failures.isEmpty {
            // Name every failure, matched back to the finding it came from.
            // Surfacing one arbitrary message left the user unable to tell
            // WHICH repairs failed out of several.
            let titles = Dictionary(
                uniqueKeysWithValues: current.safelyRepairable.map { ($0.id, $0.title) }
            )
            repairError = failures
                .sorted { $0.key < $1.key }
                .map { "\(titles[$0.key] ?? $0.key): \($0.value)" }
                .joined(separator: "\n\n")
        }
        await scan()
    }

    func dismissRepairError() { repairError = nil }
}
