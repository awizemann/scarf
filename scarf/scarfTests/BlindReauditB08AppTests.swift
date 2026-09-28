import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit B08, app-target half: cron run output, Run Now's
/// diagnostics refresh and the MCP editor's Clear Token state.
@Suite struct BlindReauditB08AppTests {

    // MARK: - S08-F1: a monitor snapshot is not run output

    /// A monitor job's per-job dir holds `monitor_last_output.txt`
    /// (`cron/monitor.py:30,62-64` @ v2026.9.24), which sorts after every
    /// `<YYYY-MM-DD_HH-MM-SS>.md` run file. Hermes lists only `*.md` as run
    /// output (`cron/jobs.py:3267`, `tools/cronjob_tools.py:379`).
    @Test func lastRunOutputIgnoresTheMonitorSnapshot() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let dir = home.context.paths.cronOutputDir + "/job1"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "old run".write(toFile: dir + "/2026-09-27_09-00-00.md", atomically: true, encoding: .utf8)
        try "latest run".write(toFile: dir + "/2026-09-27_10-00-00.md", atomically: true, encoding: .utf8)
        try "<html>fetched page</html>".write(
            toFile: dir + "/monitor_last_output.txt", atomically: true, encoding: .utf8)

        let service = HermesFileService(context: home.context)
        #expect(service.loadCronOutput(jobId: "job1") == "latest run")
    }

    /// A job whose only file is the snapshot has no run output yet.
    @Test func aSnapshotAloneIsNoOutput() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let dir = home.context.paths.cronOutputDir + "/job2"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "stdout".write(toFile: dir + "/monitor_last_output.txt", atomically: true, encoding: .utf8)
        #expect(HermesFileService(context: home.context).loadCronOutput(jobId: "job2") == nil)
    }

    // MARK: - S08-F3: Run Now refreshes doctor findings and incidents

    @MainActor
    @Test func runNowAsksForTheDiagnosticsRefresh() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = CronViewModel(context: home.context, mutationRunner: { args, _ in
            args.starts(with: ["cron", "run"])
                ? ("Triggered job: Nightly (j1)\n  Ran now: failed.\n", 0)
                : ("", 0)
        })
        let job = HermesCronJob(id: "j1", name: "Nightly", prompt: "p", model: nil,
                                schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                                enabled: true, state: "scheduled")
        #expect(vm.diagnosticsRefreshRequests == 0)
        vm.runNow(job)
        for _ in 0..<400 where vm.isRunningNow(job) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!vm.isRunningNow(job))
        #expect(vm.diagnosticsRefreshRequests >= 1)
        // Nothing had answered yet on this host, so the gate kept the refresh
        // from spawning either probe (C1).
        #expect(vm.isLoadingDoctor == false)
        #expect(vm.isLoadingIncidents == false)
    }

    // MARK: - S15 handoff: an exit-0 cron refusal is a failure on the Mac

    @MainActor
    @Test func anExitZeroPauseRefusalIsReportedAsAFailure() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = CronViewModel(context: home.context, mutationRunner: { _, _ in
            ("Failed to pause job: Job with ID or name 'j1' not found.\n", 0)
        })
        let job = HermesCronJob(id: "j1", name: "Nightly", prompt: "p", model: nil,
                                schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                                enabled: true, state: "scheduled")
        vm.pauseJob(job)
        for _ in 0..<400 where vm.message == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(vm.messageOutcome == .failure)
        #expect(vm.message?.contains("Failed to pause job") == true)
    }

    // MARK: - S09-F1: Clear Token updates the editor

    private static func oauthServer(name: String) -> HermesMCPServer {
        HermesMCPServer(
            name: name, transport: .http, command: nil, args: [],
            url: "https://mcp.example.com", auth: "oauth", env: [:], headers: [:],
            timeout: nil, connectTimeout: nil, enabled: true,
            toolsInclude: [], toolsExclude: [], resourcesEnabled: true,
            promptsEnabled: true, hasOAuthToken: true
        )
    }

    @MainActor
    @Test func clearTokenMarksTheEditorCleared() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let tokens = home.context.paths.mcpTokensDir
        try FileManager.default.createDirectory(atPath: tokens, withIntermediateDirectories: true)
        try "{}".write(toFile: tokens + "/docs.json", atomically: true, encoding: .utf8)

        let vm = MCPServerEditorViewModel(server: Self.oauthServer(name: "docs"), context: home.context)
        #expect(vm.tokenCleared == false)
        let ok: Bool = await withCheckedContinuation { cont in
            vm.clearOAuthToken { cont.resume(returning: $0) }
        }
        #expect(ok)
        #expect(vm.tokenCleared)
        #expect(!FileManager.default.fileExists(atPath: tokens + "/docs.json"))
    }

    /// A delete that fails leaves the token on disk, and the editor must keep
    /// saying so.
    @MainActor
    @Test func aFailedClearLeavesTheTokenState() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let tokens = home.context.paths.mcpTokensDir
        try FileManager.default.createDirectory(atPath: tokens, withIntermediateDirectories: true)
        try "{}".write(toFile: tokens + "/docs.json", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tokens)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tokens) }

        let vm = MCPServerEditorViewModel(server: Self.oauthServer(name: "docs"), context: home.context)
        let ok: Bool = await withCheckedContinuation { cont in
            vm.clearOAuthToken { cont.resume(returning: $0) }
        }
        #expect(!ok)
        #expect(vm.tokenCleared == false)
        #expect(FileManager.default.fileExists(atPath: tokens + "/docs.json"))
    }
}
