import Foundation
import Observation

/// iOS Cron view-state. Loads `~/.hermes/cron/jobs.json` via the
/// transport, decodes into `CronJobsFile` (Codable, from M0a),
/// exposes the sorted list for SwiftUI.
///
/// M6 adds write paths: toggle enabled, delete, and upsert (add or
/// replace a job by id). All writes re-encode the full file with a
/// fresh `updatedAt` and call `transport.writeFile` — which on iOS
/// dispatches to Citadel SFTP with atomic rename semantics.
@Observable
@MainActor
public final class IOSCronViewModel {
    public let context: ServerContext

    public private(set) var jobs: [HermesCronJob] = []
    public private(set) var isLoading: Bool = true
    public private(set) var isSaving: Bool = false
    public private(set) var lastError: String?

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.cronJobsJSON

        let result: Result<CronJobsFile, Error> = await Task.detached {
            do {
                guard let data = ctx.readData(path) else {
                    throw LoadError.missingFile(path: path)
                }
                let decoded = try JSONDecoder().decode(CronJobsFile.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let file):
            jobs = Self.sorted(file.jobs)
            isLoading = false

        case .failure(let err as LoadError):
            // Missing jobs.json is the common case on a fresh Hermes
            // install — don't surface as an error, show an empty
            // list + hint in the UI.
            if case .missingFile = err {
                jobs = []
            } else {
                lastError = err.localizedDescription
            }
            isLoading = false

        case .failure(let err):
            lastError = "Couldn't parse jobs.json: \(err.localizedDescription)"
            isLoading = false
        }
    }

    /// Toggle `enabled` on the job with the given id, re-encode, and
    /// write back. On failure, leaves the in-memory state unchanged
    /// and sets `lastError`.
    @discardableResult
    public func toggleEnabled(id: String) async -> Bool {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return false }
        var updated = jobs
        let prev = updated[idx]
        updated[idx] = prev.withEnabled(!prev.enabled)
        return await saveJobs(updated)
    }

    /// Remove the job with `id` and save.
    @discardableResult
    public func delete(id: String) async -> Bool {
        let updated = jobs.filter { $0.id != id }
        guard updated.count != jobs.count else { return false }
        return await saveJobs(updated)
    }

    /// Add a new job or replace an existing one with matching id.
    @discardableResult
    public func upsert(_ job: HermesCronJob) async -> Bool {
        var updated = jobs
        if let idx = updated.firstIndex(where: { $0.id == job.id }) {
            updated[idx] = job
        } else {
            updated.append(job)
        }
        return await saveJobs(updated)
    }

    // MARK: - Internal

    /// Shared persistence path: serialize `CronJobsFile` as pretty
    /// JSON, write it atomically through the transport, and update
    /// the in-memory list on success.
    private func saveJobs(_ newJobs: [HermesCronJob]) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        lastError = nil
        let ctx = context
        let path = ctx.paths.cronJobsJSON

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let file = CronJobsFile(jobs: newJobs, updatedAt: iso.string(from: Date()))

        let ok: Bool = await Task.detached {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                let transport = ctx.makeTransport()
                // Ensure the cron/ directory exists — on a fresh
                // Hermes install this file won't be present.
                // `createDirectory` is mkdir -p across all transports;
                // call unconditionally and let writeFile surface any
                // real failure.
                let parent = (path as NSString).deletingLastPathComponent
                try? transport.createDirectory(parent)
                try transport.writeFile(path, data: data)
                return true
            } catch {
                return false
            }
        }.value

        isSaving = false
        if ok {
            jobs = Self.sorted(newJobs)
            return true
        } else {
            lastError = "Couldn't save jobs.json — check the connection and try again."
            return false
        }
    }

    /// Sort: enabled first, then by `nextRunAt` ascending (nil last,
    /// then by name). Matches the Mac app's list rendering.
    private static func sorted(_ jobs: [HermesCronJob]) -> [HermesCronJob] {
        jobs.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            switch (lhs.nextRunAt, rhs.nextRunAt) {
            case (let l?, let r?): return l < r
            case (_?, nil):        return true
            case (nil, _?):        return false
            case (nil, nil):       return lhs.name < rhs.name
            }
        }
    }

    public enum LoadError: Error, LocalizedError {
        case missingFile(path: String)

        public var errorDescription: String? {
            switch self {
            case .missingFile(let p): return "No cron jobs defined (\(p) doesn't exist yet)"
            }
        }
    }
}

// MARK: - HermesCronJob helpers

public extension HermesCronJob {
    /// Return a copy with a different `enabled` flag. Used by the iOS
    /// Cron list's toggle. All other fields pass through unchanged.
    func withEnabled(_ newEnabled: Bool) -> HermesCronJob {
        HermesCronJob(
            id: id,
            name: name,
            prompt: prompt,
            skills: skills,
            model: model,
            schedule: schedule,
            enabled: newEnabled,
            state: state,
            deliver: deliver,
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastError: lastError,
            preRunScript: preRunScript,
            deliveryFailures: deliveryFailures,
            lastDeliveryError: lastDeliveryError,
            timeoutType: timeoutType,
            timeoutSeconds: timeoutSeconds,
            silent: silent
        )
    }
}
