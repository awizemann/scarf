import Foundation
import Observation

/// iOS read-only Cron view-state. Loads `~/.hermes/cron/jobs.json`
/// via the transport, decodes into `CronJobsFile` (already Codable
/// in ScarfCore), exposes the list for SwiftUI.
///
/// M5 is read-only by design — editing cron jobs (add / delete /
/// toggle enabled) is deferred until we have a clearer iOS story for
/// rewriting `jobs.json` atomically across the SSH SFTP path. The
/// Mac app's `CronViewModel` does this through `HermesFileService`;
/// porting that is out of scope for M5.
@Observable
@MainActor
public final class IOSCronViewModel {
    public let context: ServerContext

    public private(set) var jobs: [HermesCronJob] = []
    public private(set) var isLoading: Bool = true
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
            // Sort: enabled first, then by nextRunAt ascending (nil
            // last). Matches what the Mac app does for list rendering.
            jobs = file.jobs.sorted { lhs, rhs in
                if lhs.enabled != rhs.enabled { return lhs.enabled }
                switch (lhs.nextRunAt, rhs.nextRunAt) {
                case (let l?, let r?): return l < r
                case (_?, nil):        return true
                case (nil, _?):        return false
                case (nil, nil):       return lhs.name < rhs.name
                }
            }
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

    public enum LoadError: Error, LocalizedError {
        case missingFile(path: String)

        public var errorDescription: String? {
            switch self {
            case .missingFile(let p): return "No cron jobs defined (\(p) doesn't exist yet)"
            }
        }
    }
}
