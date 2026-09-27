import Foundation
import Observation
import ScarfCore
import os

/// Drives `BackupServerSheet`. Splits the user-facing flow into three
/// phases (preflight → run → done | failed) so the sheet renders one
/// coherent screen per phase. The actual backup work runs as a `Task`
/// that this VM owns; cancellation tears the SSH stream down via
/// `Task.checkCancellation()` checks inside `RemoteBackupService.run`.
@Observable
@MainActor
final class BackupServerViewModel {
    enum Phase: Equatable {
        case loading
        case ready(RemoteBackupService.PreflightSummary)
        case running(RemoteBackupService.Progress)
        case done(RemoteBackupService.BackupResult)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case (.ready(let a), .ready(let b)): return a == b
            case (.running(let a), .running(let b)): return a == b
            case (.done, .done): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private static let logger = Logger(subsystem: "com.scarf", category: "BackupServerViewModel")

    let context: ServerContext
    var phase: Phase = .loading
    var includeAuth = false
    var includeMcpTokens = false
    var includeLogs = false
    var bytesPushedHermes: Int64 = 0
    var bytesPushedCurrentProject: Int64 = 0
    var currentProjectName: String?

    private var workTask: Task<Void, Never>?

    init(context: ServerContext) {
        self.context = context
    }

    func start() async {
        let service = RemoteBackupService(context: context)
        do {
            let summary = try await service.preflight()
            phase = .ready(summary)
        } catch {
            phase = .failed(error.localizedDescription)
            Self.logger.error("Backup preflight failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func runBackup(to destination: URL, summary: RemoteBackupService.PreflightSummary) {
        let options = BackupManifest.Options(
            includeAuth: includeAuth,
            includeMcpTokens: includeMcpTokens,
            includeLogs: includeLogs,
            // Scarf never checkpoints (writes) state.db (charter C3); the
            // service snapshots it read-only instead.
            checkpointedWAL: false
        )
        phase = .running(.preflight)
        // Two-step capture: the outer task gets [weak self] so a sheet
        // dismiss-mid-run doesn't pin the VM; once the task starts we
        // promote to a strong reference so the @Sendable progress
        // callback (called off-actor by the service) can hop back via
        // an unowned hop without the Swift 6 capture warning.
        let weakSelf = WeakBox(self)
        workTask = Task { @MainActor in
            guard let viewModel = weakSelf.value else { return }
            let service = RemoteBackupService(context: viewModel.context)
            do {
                let result = try await service.run(
                    preflight: summary,
                    options: options,
                    archiveURL: destination,
                    progress: { step in
                        Task { @MainActor in
                            weakSelf.value?.applyProgress(step)
                        }
                    }
                )
                viewModel.phase = .done(result)
            } catch is CancellationError {
                viewModel.phase = .failed("Cancelled.")
            } catch {
                viewModel.phase = .failed(error.localizedDescription)
                Self.logger.error("Backup run failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Tiny weak-reference box that's `Sendable` even when its
    /// referent isn't (the value is fetched on the actor). Lets us
    /// pass a "weak self" handle through `@Sendable` closures
    /// without the Swift 6 var-self warning.
    private final class WeakBox: @unchecked Sendable {
        weak var value: BackupServerViewModel?
        init(_ v: BackupServerViewModel) { self.value = v }
    }

    func cancel() {
        workTask?.cancel()
        workTask = nil
    }

    private func applyProgress(_ step: RemoteBackupService.Progress) {
        switch step {
        case .archivingHermes(let n):
            bytesPushedHermes = n
        case .archivingProject(let name, let n):
            currentProjectName = name
            bytesPushedCurrentProject = n
        default:
            break
        }
        phase = .running(step)
    }

    /// Default filename for the save panel — `<displayName>-<date>.scarfbackup`.
    /// Slug-cased so it survives Finder display.
    var defaultArchiveName: String {
        let stamp = Self.timestamp()
        let slug = context.displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let leaf = slug.isEmpty ? "scarf" : slug
        return "\(leaf)-\(stamp).scarfbackup"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
