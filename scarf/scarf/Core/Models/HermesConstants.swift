import Foundation

enum HermesPaths: Sendable {
    // Using ProcessInfo to avoid main-actor isolation issues with FileManager/NSHomeDirectory
    nonisolated static let home: String = ProcessInfo.processInfo.environment["HOME"]! + "/.hermes"
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
    nonisolated static let gatewayLog: String = home + "/logs/gateway.log"
    nonisolated static let hermesBinary: String = ProcessInfo.processInfo.environment["HOME"]! + "/.local/bin/hermes"
    nonisolated static let scarfDir: String = home + "/scarf"
    nonisolated static let projectsRegistry: String = scarfDir + "/projects.json"
}
