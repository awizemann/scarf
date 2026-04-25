import Testing
import Foundation
@testable import ScarfCore

/// M5 iOS feature ViewModels: Memory (read/write), Cron (read-only
/// JSON), Skills (read-only directory scan). All exercised through
/// `LocalTransport` against tmpfs paths so the suite runs on Linux
/// CI with the same file-I/O codepaths iOS hits (just without SFTP
/// in front).
@Suite(.serialized) struct M5FeatureVMTests {

    /// Build a context rooted at a fresh tmp directory. Also pre-
    /// creates the Hermes subfolders so the VMs' `paths.*` resolve
    /// to real locations.
    @MainActor
    private func makeFakeHermes() throws -> (context: ServerContext, home: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-m5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // We can't easily override ServerContext.paths without building
        // a new ServerKind, and HermesPathSet is keyed on "home". So
        // we LIE to ServerContext.local by symlinking? No — too risky.
        // Instead: construct a remote-kind context whose remoteHome
        // points at our tmp dir, then install a custom transport
        // factory that returns a LocalTransport pointed at local
        // files. LocalTransport ignores the path's "remote-ness"
        // since on Linux everything resolves to the actual FS.
        let kind = ServerKind.ssh(SSHConfig(host: "fake.invalid", remoteHome: tmp.path))
        let ctx = ServerContext(id: UUID(), displayName: "fake", kind: kind)
        // Pre-create subdirs the VMs look for.
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("memories"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("cron"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("skills"),
            withIntermediateDirectories: true
        )
        return (ctx, tmp)
    }

    /// Wrap each test body in a factory override so `ctx.makeTransport()`
    /// returns a `LocalTransport` instead of trying to spawn a real SSH
    /// subprocess. The `.serialized` suite trait guarantees no other test
    /// in *this* suite races on the factory static. Cross-suite races used
    /// to bite us when M3TransportTests ran in parallel — fixed by moving
    /// every factory-touching test into this suite.
    @MainActor
    private func withLocalTransportFactory<T>(
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = { id, _, _ in
            LocalTransport(contextID: id)
        }
        return try await body()
    }

    // MARK: - Memory

    @Test @MainActor func memoryLoadsEmptyWhenFileMissing() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
            await vm.load()
            #expect(vm.text == "")
            #expect(vm.originalText == "")
            #expect(vm.isLoading == false)
            #expect(vm.hasUnsavedChanges == false)
        }
    }

    @Test @MainActor func memoryRoundTripsFileContent() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            // Seed a MEMORY.md file.
            let seed = "# Known facts\n\n- scarf is a Hermes companion\n"
            try seed.write(
                to: home.appendingPathComponent("memories/MEMORY.md"),
                atomically: true,
                encoding: .utf8
            )

            let vm = IOSMemoryViewModel(kind: .memory, context: ctx)
            await vm.load()
            #expect(vm.text == seed)
            #expect(vm.originalText == seed)
            #expect(!vm.hasUnsavedChanges)

            vm.text = seed + "- also does iOS now\n"
            #expect(vm.hasUnsavedChanges)

            let saved = await vm.save()
            #expect(saved)
            #expect(!vm.hasUnsavedChanges)

            // Re-load via a fresh VM to confirm persistence.
            let vm2 = IOSMemoryViewModel(kind: .memory, context: ctx)
            await vm2.load()
            #expect(vm2.text.contains("iOS"))
        }
    }

    @Test @MainActor func memoryRevertRestoresOriginal() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            try "seed".write(
                to: home.appendingPathComponent("memories/USER.md"),
                atomically: true,
                encoding: .utf8
            )
            let vm = IOSMemoryViewModel(kind: .user, context: ctx)
            await vm.load()
            vm.text = "scratch edit"
            #expect(vm.hasUnsavedChanges)
            vm.revert()
            #expect(vm.text == "seed")
            #expect(!vm.hasUnsavedChanges)
        }
    }

    @Test func memoryKindPathRouting() {
        // Pin that .memory → memoryMD, .user → userMD.
        let ctx = ServerContext.local
        #expect(IOSMemoryViewModel.Kind.memory.path(on: ctx) == ctx.paths.memoryMD)
        #expect(IOSMemoryViewModel.Kind.user.path(on: ctx) == ctx.paths.userMD)
    }

    // MARK: - Cron

    @Test @MainActor func cronEmptyWhenJobsFileMissing() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSCronViewModel(context: ctx)
            await vm.load()
            #expect(vm.jobs.isEmpty)
            #expect(vm.lastError == nil) // "missing file" is not an error
            #expect(vm.isLoading == false)
        }
    }

    @Test @MainActor func cronLoadsAndSortsJobs() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            // Two enabled, one disabled — verify disabled sinks to bottom.
            let json = #"""
            {
              "jobs": [
                {
                  "id": "b",
                  "name": "Late riser",
                  "prompt": "brief me",
                  "skills": null,
                  "model": null,
                  "schedule": {"kind": "cron", "run_at": null, "display": "9am weekdays", "expression": "0 9 * * 1-5"},
                  "enabled": true,
                  "state": "scheduled",
                  "deliver": null,
                  "next_run_at": "2026-04-24T09:00:00Z",
                  "last_run_at": null,
                  "last_error": null,
                  "pre_run_script": null,
                  "delivery_failures": 0,
                  "last_delivery_error": null,
                  "timeout_type": null,
                  "timeout_seconds": null,
                  "silent": false
                },
                {
                  "id": "a",
                  "name": "Early bird",
                  "prompt": "wake me",
                  "skills": null,
                  "model": null,
                  "schedule": {"kind": "cron", "run_at": null, "display": "6am daily", "expression": "0 6 * * *"},
                  "enabled": true,
                  "state": "scheduled",
                  "deliver": "discord:general",
                  "next_run_at": "2026-04-23T06:00:00Z",
                  "last_run_at": null,
                  "last_error": null,
                  "pre_run_script": null,
                  "delivery_failures": 0,
                  "last_delivery_error": null,
                  "timeout_type": null,
                  "timeout_seconds": null,
                  "silent": false
                },
                {
                  "id": "c",
                  "name": "Off",
                  "prompt": "quiet",
                  "skills": null,
                  "model": null,
                  "schedule": {"kind": "interval", "run_at": null, "display": "every hour", "expression": null},
                  "enabled": false,
                  "state": "scheduled",
                  "deliver": null,
                  "next_run_at": null,
                  "last_run_at": null,
                  "last_error": null,
                  "pre_run_script": null,
                  "delivery_failures": 0,
                  "last_delivery_error": null,
                  "timeout_type": null,
                  "timeout_seconds": null,
                  "silent": false
                }
              ],
              "updated_at": "2026-04-22T12:00:00Z"
            }
            """#
            try json.write(
                to: home.appendingPathComponent("cron/jobs.json"),
                atomically: true,
                encoding: .utf8
            )
            let vm = IOSCronViewModel(context: ctx)
            await vm.load()
            #expect(vm.lastError == nil)
            #expect(vm.jobs.count == 3)
            // Enabled + next_run_at earlier → first
            #expect(vm.jobs[0].name == "Early bird")
            #expect(vm.jobs[1].name == "Late riser")
            // Disabled → last
            #expect(vm.jobs[2].name == "Off")
            #expect(vm.jobs[0].deliveryDisplay?.contains("Discord") == true)
        }
    }

    @Test @MainActor func cronSurfacesDecodeErrors() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            try "garbage, not json".write(
                to: home.appendingPathComponent("cron/jobs.json"),
                atomically: true,
                encoding: .utf8
            )
            let vm = IOSCronViewModel(context: ctx)
            await vm.load()
            #expect(vm.lastError != nil)
            #expect(vm.jobs.isEmpty)
        }
    }

    // MARK: - Skills

    @Test @MainActor func skillsEmptyWhenDirMissing() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            // Remove the skills/ dir we pre-created.
            try FileManager.default.removeItem(
                at: home.appendingPathComponent("skills")
            )
            let vm = IOSSkillsViewModel(context: ctx)
            await vm.load()
            #expect(vm.categories.isEmpty)
            #expect(vm.lastError == nil)
        }
    }

    @Test @MainActor func skillsScansCategoryAndSkillStructure() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            let skills = home.appendingPathComponent("skills")
            let dev = skills.appendingPathComponent("dev")
            let personal = skills.appendingPathComponent("personal")
            try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
            // dev/git/
            let devGit = dev.appendingPathComponent("git")
            try FileManager.default.createDirectory(at: devGit, withIntermediateDirectories: true)
            try "".write(to: devGit.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try "".write(to: devGit.appendingPathComponent("helpers.sh"), atomically: true, encoding: .utf8)
            // personal/journaling/
            let pJournal = personal.appendingPathComponent("journaling")
            try FileManager.default.createDirectory(at: pJournal, withIntermediateDirectories: true)
            try "".write(to: pJournal.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            // Dotfile should be filtered
            try "".write(to: pJournal.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

            let vm = IOSSkillsViewModel(context: ctx)
            await vm.load()
            #expect(vm.categories.count == 2)
            #expect(vm.categories[0].name == "dev")
            #expect(vm.categories[1].name == "personal")
            #expect(vm.categories[0].skills.count == 1)
            #expect(vm.categories[0].skills[0].name == "git")
            #expect(vm.categories[0].skills[0].files.sorted() == ["SKILL.md", "helpers.sh"])
            // Dotfile filtered out
            #expect(vm.categories[1].skills[0].files == ["SKILL.md"])
        }
    }

    @Test @MainActor func skillsSkipsEmptyCategories() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            // Empty category shouldn't appear in the list.
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("skills/empty-cat"),
                withIntermediateDirectories: true
            )
            let vm = IOSSkillsViewModel(context: ctx)
            await vm.load()
            #expect(vm.categories.isEmpty)
        }
    }

    // MARK: - RichChatViewModel PendingPermission public init

    #if canImport(SQLite3)
    @Test func pendingPermissionMemberwise() {
        let p = RichChatViewModel.PendingPermission(
            requestId: 99,
            title: "write_file: /etc/hosts",
            kind: "edit",
            options: [("allow", "Allow once"), ("deny", "Deny")]
        )
        #expect(p.requestId == 99)
        #expect(p.title == "write_file: /etc/hosts")
        #expect(p.kind == "edit")
        #expect(p.options.count == 2)
        #expect(p.options[0].optionId == "allow")
    }
    #endif

    // MARK: - M0b default SSH transport factory path
    //
    // Moved here from M0bTransportTests because it asserts the
    // default-factory (nil) behavior — which any other test in a
    // parallel suite installing a custom factory would clobber.
    // Living in a .serialized suite + explicitly resetting the
    // factory makes the assertion race-free.

    @Test @MainActor func defaultFactoryProducesSSHTransportForRemoteContext() {
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = nil

        let remoteCtx = ServerContext(
            id: UUID(),
            displayName: "r",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let remote = remoteCtx.makeTransport()
        #expect(remote is SSHTransport)
        #expect(remote.isRemote == true)
        #expect(remote.contextID == remoteCtx.id)
    }

    // MARK: - M3 sshTransportFactory injection + HermesLogService remote tail
    //
    // Moved from M3TransportTests in v2.5. Both suites had `.serialized`
    // internally but ran in parallel with each other, clobbering the
    // `ServerContext.sshTransportFactory` static. Co-locating them in a
    // single `.serialized` suite fixes the race; logic is unchanged.

    @Test @MainActor func sshTransportFactoryOverridesDefault() {
        // Set up a mock factory that returns a `LocalTransport` regardless
        // of the ServerKind — easy way to prove the injection point
        // routes to our override.
        final class CountingBox: @unchecked Sendable {
            var count = 0
            func bump() { count += 1 }
        }
        let box = CountingBox()
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }

        ServerContext.sshTransportFactory = { id, _, _ in
            box.bump()
            return LocalTransport(contextID: id)
        }

        let ctx = ServerContext(
            id: UUID(),
            displayName: "test",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let transport = ctx.makeTransport()
        #expect(transport is LocalTransport)
        #expect(box.count == 1)
    }

    @Test @MainActor func sshTransportFactoryNilFallsBackToSSHTransport() {
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = nil

        let ctx = ServerContext(
            id: UUID(),
            displayName: "test",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let transport = ctx.makeTransport()
        #expect(transport is SSHTransport)
    }

    @Test @MainActor func sshTransportFactoryIgnoredForLocalContext() {
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        // Even if set, the factory is ONLY consulted for `.ssh` kinds —
        // `.local` always gets a `LocalTransport` directly.
        ServerContext.sshTransportFactory = { _, _, _ in
            Issue.record("factory called for local context")
            return LocalTransport()
        }

        let transport = ServerContext.local.makeTransport()
        #expect(transport is LocalTransport)
    }

    /// Minimal `ServerTransport` test double: `isRemote == true`, all
    /// file I/O throws, `streamLines` returns a scripted sequence of
    /// lines. Exists to verify HermesLogService's remote-tail path
    /// pumps scripted output into the ring buffer without a real SSH
    /// subprocess.
    final class ScriptedTransport: ServerTransport, @unchecked Sendable {
        public let contextID: ServerID = UUID()
        public let isRemote: Bool = true
        private let lines: [String]

        init(lines: [String]) { self.lines = lines }

        func readFile(_ path: String) throws -> Data { throw TransportError.other(message: "N/A") }
        func writeFile(_ path: String, data: Data) throws { throw TransportError.other(message: "N/A") }
        func fileExists(_ path: String) -> Bool { true }
        func stat(_ path: String) -> FileStat? { FileStat(size: 0, mtime: Date(), isDirectory: false) }
        func listDirectory(_ path: String) throws -> [String] { [] }
        func createDirectory(_ path: String) throws {}
        func removeFile(_ path: String) throws {}
        func runProcess(executable: String, args: [String], stdin: Data?, timeout: TimeInterval?) throws -> ProcessResult {
            // For readLastLines' one-shot tail — return all scripted lines joined.
            let content = lines.joined(separator: "\n") + "\n"
            return ProcessResult(exitCode: 0, stdout: Data(content.utf8), stderr: Data())
        }
        #if !os(iOS)
        func makeProcess(executable: String, args: [String]) -> Process {
            // Required by protocol on non-iOS; not exercised in tests below.
            Process()
        }
        #endif
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                }
            }
        }
        func snapshotSQLite(remotePath: String) throws -> URL { URL(fileURLWithPath: remotePath) }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> {
            AsyncStream { $0.finish() }
        }
    }

    @Test @MainActor func hermesLogServiceRemoteTailPumpsThroughStreamLines() async throws {
        let scripted = ScriptedTransport(lines: [
            "2026-04-22 12:00:00,001 INFO hermes.agent: starting",
            "2026-04-22 12:00:01,002 WARNING hermes.gateway: low disk",
            "2026-04-22 12:00:02,003 ERROR hermes.agent: boom",
        ])

        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = { _, _, _ in scripted }

        let ctx = ServerContext(
            id: UUID(),
            displayName: "t",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let service = HermesLogService(context: ctx)
        await service.openLog(path: "/fake/agent.log")
        defer { Task { await service.closeLog() } }

        // Give the pump task a moment to drain the scripted stream.
        try await Task.sleep(nanoseconds: 50_000_000)

        let entries = await service.readNewLines()
        #expect(entries.count == 3)
        #expect(entries[0].level == .info)
        #expect(entries[1].level == .warning)
        #expect(entries[2].level == .error)
        #expect(entries[2].message == "boom")
    }

    @Test @MainActor func hermesLogServiceReadLastLinesUsesOneShotTail() async {
        let scripted = ScriptedTransport(lines: ["x", "y", "z"])
        let previous = ServerContext.sshTransportFactory
        defer { ServerContext.sshTransportFactory = previous }
        ServerContext.sshTransportFactory = { _, _, _ in scripted }

        let ctx = ServerContext(
            id: UUID(),
            displayName: "t",
            kind: .ssh(SSHConfig(host: "h"))
        )
        let service = HermesLogService(context: ctx)
        // Doesn't need openLog first for the one-shot, but currentPath
        // has to be set — openLog does both.
        await service.openLog(path: "/fake/agent.log")
        defer { Task { await service.closeLog() } }

        let entries = await service.readLastLines(count: 100)
        #expect(entries.count == 3)
        #expect(entries[0].message == "x")
        #expect(entries[2].message == "z")
    }

    // MARK: - M6 Cron editing (write paths)
    //
    // Live in this suite (rather than M6ConfigCronTests) because they
    // install the `ServerContext.sshTransportFactory` static — same
    // pattern as the Memory/Cron/Skills read-path tests above. Mixing
    // factory-users across multiple `.serialized` suites races on
    // the static, so M6's factory-touching tests merge here.

    @Test @MainActor func cronUpsertCreatesFileFromScratch() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSCronViewModel(context: ctx)
            await vm.load()
            #expect(vm.jobs.isEmpty)

            let job = HermesCronJob(
                id: "job_abc",
                name: "Morning brief",
                prompt: "summarize my calendar",
                skills: ["calendar"],
                model: nil,
                schedule: CronSchedule(kind: "cron", display: "9am", expression: "0 9 * * *"),
                enabled: true,
                state: "scheduled"
            )
            let ok = await vm.upsert(job)
            #expect(ok)
            #expect(vm.jobs.count == 1)
            #expect(vm.jobs[0].name == "Morning brief")

            let vm2 = IOSCronViewModel(context: ctx)
            await vm2.load()
            #expect(vm2.jobs.count == 1)
            #expect(vm2.jobs[0].id == "job_abc")
            #expect(vm2.jobs[0].prompt == "summarize my calendar")
            #expect(vm2.jobs[0].skills == ["calendar"])
        }
    }

    @Test @MainActor func cronToggleEnabledPersists() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSCronViewModel(context: ctx)
            await vm.upsert(HermesCronJob(
                id: "j1", name: "A", prompt: "p",
                schedule: CronSchedule(kind: "cron"),
                enabled: true, state: "scheduled"
            ))
            #expect(vm.jobs[0].enabled)
            let ok = await vm.toggleEnabled(id: "j1")
            #expect(ok)
            #expect(vm.jobs[0].enabled == false)

            let vm2 = IOSCronViewModel(context: ctx)
            await vm2.load()
            #expect(vm2.jobs[0].enabled == false)
        }
    }

    @Test @MainActor func cronDeleteRemovesJob() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSCronViewModel(context: ctx)
            await vm.upsert(HermesCronJob(id: "a", name: "A", prompt: "p", schedule: CronSchedule(kind: "cron"), enabled: true, state: "scheduled"))
            await vm.upsert(HermesCronJob(id: "b", name: "B", prompt: "q", schedule: CronSchedule(kind: "cron"), enabled: true, state: "scheduled"))
            #expect(vm.jobs.count == 2)

            let ok = await vm.delete(id: "a")
            #expect(ok)
            #expect(vm.jobs.count == 1)
            #expect(vm.jobs[0].id == "b")

            let vm2 = IOSCronViewModel(context: ctx)
            await vm2.load()
            #expect(vm2.jobs.count == 1)
            #expect(vm2.jobs[0].id == "b")
        }
    }

    @Test @MainActor func cronUpsertReplacesMatchingId() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSCronViewModel(context: ctx)
            await vm.upsert(HermesCronJob(
                id: "j1", name: "Original", prompt: "p1",
                schedule: CronSchedule(kind: "cron"),
                enabled: true, state: "scheduled"
            ))
            await vm.upsert(HermesCronJob(
                id: "j1", name: "Renamed", prompt: "p2",
                schedule: CronSchedule(kind: "interval"),
                enabled: false, state: "scheduled"
            ))
            #expect(vm.jobs.count == 1)
            #expect(vm.jobs[0].name == "Renamed")
            #expect(vm.jobs[0].prompt == "p2")
            #expect(vm.jobs[0].enabled == false)
        }
    }

    @Test @MainActor func cronPreservesRuntimeFieldsAcrossReloads() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSCronViewModel(context: ctx)
            await vm.upsert(HermesCronJob(
                id: "j1", name: "Kept", prompt: "p",
                skills: nil, model: "gpt-4",
                schedule: CronSchedule(kind: "cron", display: "midnight"),
                enabled: true,
                state: "completed",
                deliver: "discord:general",
                nextRunAt: "2026-04-25T00:00:00Z",
                lastRunAt: "2026-04-24T00:00:00Z",
                deliveryFailures: 3,
                lastDeliveryError: "rate limited",
                timeoutType: "soft",
                timeoutSeconds: 600,
                silent: false
            ))

            let vm2 = IOSCronViewModel(context: ctx)
            await vm2.load()
            let j = vm2.jobs[0]
            #expect(j.nextRunAt == "2026-04-25T00:00:00Z")
            #expect(j.lastRunAt == "2026-04-24T00:00:00Z")
            #expect(j.deliveryFailures == 3)
            #expect(j.lastDeliveryError == "rate limited")
            #expect(j.timeoutSeconds == 600)
            #expect(j.state == "completed")
        }
    }

    // MARK: - M6 Settings

    @Test @MainActor func settingsLoadsFromConfigYAML() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, home) = try makeFakeHermes()
            let yaml = """
            model:
              default: gpt-4o
              provider: openai
            display:
              skin: solarized
              compact: true
            """
            try yaml.write(
                to: home.appendingPathComponent("config.yaml"),
                atomically: true,
                encoding: .utf8
            )
            let vm = IOSSettingsViewModel(context: ctx)
            await vm.load()
            #expect(vm.isLoading == false)
            #expect(vm.config.model == "gpt-4o")
            #expect(vm.config.provider == "openai")
            #expect(vm.config.display.skin == "solarized")
            #expect(vm.config.display.compact == true)
            #expect(vm.rawYAML.contains("gpt-4o"))
            #expect(vm.lastError == nil)
        }
    }

    @Test @MainActor func settingsSurfacesMissingFile() async throws {
        try await withLocalTransportFactory { [self] in
            let (ctx, _) = try makeFakeHermes()
            let vm = IOSSettingsViewModel(context: ctx)
            await vm.load()
            #expect(vm.isLoading == false)
            #expect(vm.lastError != nil)
            #expect(vm.config.model == "unknown")
        }
    }
}
