import Foundation
import SQLite3

/// Deprecated module-level path statics. Preserved as thin forwarders to
/// `ServerContext.local.paths` so existing call sites continue to compile
/// while Phase 1 migrates them to a per-server `ServerContext`.
///
/// New code should accept a `ServerContext` and read `context.paths.<field>`.
enum HermesPaths: Sendable {
    @available(*, deprecated, message: "use ServerContext.paths.home")
    nonisolated static var home: String { ServerContext.local.paths.home }

    @available(*, deprecated, message: "use ServerContext.paths.stateDB")
    nonisolated static var stateDB: String { ServerContext.local.paths.stateDB }

    @available(*, deprecated, message: "use ServerContext.paths.configYAML")
    nonisolated static var configYAML: String { ServerContext.local.paths.configYAML }

    @available(*, deprecated, message: "use ServerContext.paths.memoriesDir")
    nonisolated static var memoriesDir: String { ServerContext.local.paths.memoriesDir }

    @available(*, deprecated, message: "use ServerContext.paths.memoryMD")
    nonisolated static var memoryMD: String { ServerContext.local.paths.memoryMD }

    @available(*, deprecated, message: "use ServerContext.paths.userMD")
    nonisolated static var userMD: String { ServerContext.local.paths.userMD }

    @available(*, deprecated, message: "use ServerContext.paths.sessionsDir")
    nonisolated static var sessionsDir: String { ServerContext.local.paths.sessionsDir }

    @available(*, deprecated, message: "use ServerContext.paths.cronJobsJSON")
    nonisolated static var cronJobsJSON: String { ServerContext.local.paths.cronJobsJSON }

    @available(*, deprecated, message: "use ServerContext.paths.cronOutputDir")
    nonisolated static var cronOutputDir: String { ServerContext.local.paths.cronOutputDir }

    @available(*, deprecated, message: "use ServerContext.paths.gatewayStateJSON")
    nonisolated static var gatewayStateJSON: String { ServerContext.local.paths.gatewayStateJSON }

    @available(*, deprecated, message: "use ServerContext.paths.skillsDir")
    nonisolated static var skillsDir: String { ServerContext.local.paths.skillsDir }

    @available(*, deprecated, message: "use ServerContext.paths.errorsLog")
    nonisolated static var errorsLog: String { ServerContext.local.paths.errorsLog }

    @available(*, deprecated, message: "use ServerContext.paths.agentLog")
    nonisolated static var agentLog: String { ServerContext.local.paths.agentLog }

    @available(*, deprecated, message: "use ServerContext.paths.gatewayLog")
    nonisolated static var gatewayLog: String { ServerContext.local.paths.gatewayLog }

    @available(*, deprecated, message: "use ServerContext.paths.scarfDir")
    nonisolated static var scarfDir: String { ServerContext.local.paths.scarfDir }

    @available(*, deprecated, message: "use ServerContext.paths.projectsRegistry")
    nonisolated static var projectsRegistry: String { ServerContext.local.paths.projectsRegistry }

    @available(*, deprecated, message: "use ServerContext.paths.mcpTokensDir")
    nonisolated static var mcpTokensDir: String { ServerContext.local.paths.mcpTokensDir }

    @available(*, deprecated, message: "use HermesPathSet.hermesBinaryCandidates")
    nonisolated static var hermesBinaryCandidates: [String] {
        HermesPathSet.hermesBinaryCandidates
    }

    @available(*, deprecated, message: "use ServerContext.paths.hermesBinary")
    nonisolated static var hermesBinary: String { ServerContext.local.paths.hermesBinary }
}

// MARK: - SQLite Constants

/// SQLITE_TRANSIENT tells SQLite to make its own copy of bound string data.
/// The C macro is defined as ((sqlite3_destructor_type)-1) which can't be imported directly into Swift.
nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Query Defaults

enum QueryDefaults: Sendable {
    nonisolated static let sessionLimit = 100
    nonisolated static let messageSearchLimit = 50
    nonisolated static let toolCallLimit = 50
    nonisolated static let sessionPreviewLimit = 10
    nonisolated static let previewContentLength = 100
    nonisolated static let logLineLimit = 200
    nonisolated static let defaultSilenceThreshold = 200
}

// MARK: - File Size Formatting

enum FileSizeUnit: Sendable {
    nonisolated static let kilobyte = 1_024.0
    nonisolated static let megabyte = 1_048_576.0
}
