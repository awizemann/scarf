import Foundation
import SQLite3

enum HermesPaths: Sendable {
    private nonisolated static let userHome: String = ProcessInfo.processInfo.environment["HOME"]
        ?? NSHomeDirectory()

    nonisolated static let home: String = userHome + "/.hermes"
    nonisolated static let stateDB: String = home + "/state.db"
    nonisolated static let configYAML: String = home + "/config.yaml"
    nonisolated static let memoriesDir: String = home + "/memories"
    nonisolated static let memoryMD: String = memoriesDir + "/MEMORY.md"
    nonisolated static let userMD: String = memoriesDir + "/USER.md"
    nonisolated static let sessionsDir: String = home + "/sessions"
    nonisolated static let cronJobsJSON: String = home + "/cron/jobs.json"
    nonisolated static let cronOutputDir: String = home + "/cron/output"
    nonisolated static let gatewayStateJSON: String = home + "/gateway_state.json"
    nonisolated static let skillsDir: String = home + "/skills"
    nonisolated static let errorsLog: String = home + "/logs/errors.log"
    nonisolated static let agentLog: String = home + "/logs/agent.log"
    nonisolated static let gatewayLog: String = home + "/logs/gateway.log"
    nonisolated static let scarfDir: String = home + "/scarf"
    nonisolated static let projectsRegistry: String = scarfDir + "/projects.json"
    nonisolated static let mcpTokensDir: String = home + "/mcp-tokens"

    /// Install locations we look for the `hermes` binary in, in priority order.
    /// Checked every access so a user installing via a different method doesn't
    /// need to relaunch Scarf.
    nonisolated static let hermesBinaryCandidates: [String] = [
        userHome + "/.local/bin/hermes",   // pipx / pip --user (default)
        "/opt/homebrew/bin/hermes",        // Homebrew on Apple Silicon
        "/usr/local/bin/hermes",           // Homebrew on Intel / manual install
        userHome + "/.hermes/bin/hermes"   // Some self-install layouts
    ]

    /// Resolved path to the `hermes` executable. Returns the first candidate
    /// that exists and is executable; falls back to the pipx default so error
    /// messages ("Expected at …") still make sense on a fresh machine.
    nonisolated static var hermesBinary: String {
        for path in hermesBinaryCandidates
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return hermesBinaryCandidates[0]
    }
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
