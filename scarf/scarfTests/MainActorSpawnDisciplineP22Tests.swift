import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase P22 of the round-2 whole-surface audit (charter C10: "never block
/// first paint or the main actor on process spawns, SSH, or state.db reads —
/// heavy work starts lazily off-main, and every subprocess has a timeout").
///
/// P11 swept Settings and the messaging-gateway load; P22 sweeps the sites it
/// did not reach. The honest signal is the same one P11 settled on and is
/// repeated here deliberately: `Thread.isMainThread` recorded INSIDE the
/// injected fake runner. Measuring how long a synchronous `save()` took proves
/// nothing — the body is kicked off in a `Task`, which on a `@MainActor` class
/// cannot start until the caller returns, so the call is fast either way.
///
/// Every test below fails when its fix is reverted:
///
/// * the platform-setup tests fail if `commitSave` / `loadSnapshot` go back to
///   calling `PlatformSetupHelpers.saveForm` / `loadEnv` inline;
/// * the gateway tests fail if the mutations go back to `ctx.runHermes(...)`
///   (the fake runner records nothing at all then) or if the third probe goes
///   back to an unobservable transport call;
/// * the kanban test fails if `lastDiagnosticsFetchAt` is stamped only on
///   success (the fake host then spawns `kanban diagnostics` once per refresh);
/// * the MCP-login test fails if `proc.run()` goes back on the main actor;
/// * the timeout test fails if `waitUntilExit(timeout:)` waits forever.
@Suite("P22 — main-actor and spawn discipline")
@MainActor
struct MainActorSpawnDisciplineP22Tests {

    private typealias CLILog = MainActorBlockingWritesP11Tests.CLILog

    /// An isolated Hermes home so every read/write lands in a temp dir and
    /// never the developer's real `~/.hermes`.
    private static func scratchHome() -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p22-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private static func scratchContext() -> ServerContext { .local(home: scratchHome()) }

    /// Leading-space count, the proxy for declaration nesting in the
    /// indent-based walk in the sweep below.
    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// Repo root, for the source scans below (`…/scarf/scarfTests/x.swift`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    /// Poll until `condition` holds or `timeout` elapses. Load-independent:
    /// the assertions afterwards are all about WHERE work ran or HOW MANY
    /// times it ran, never how long it took.
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - 1. Platform setup forms

    /// `TelegramSetupViewModel.save()` used to do the whole `.env` write plus
    /// one `hermes config set` spawn per key inline on the main actor — on an
    /// `.ssh` context, a network round-trip each. `GatewayBehaviorViewModel`
    /// had already been detached; the per-platform forms never were.
    @Test func telegramSaveRunsOffTheMainActor() async {
        let log = CLILog()
        let vm = TelegramSetupViewModel(context: Self.scratchContext(), cliRunner: log.runner(delay: 0.05))
        vm.botToken = "123:abc"

        vm.save()
        // Synchronous kick-off: nothing has been spawned yet.
        #expect(log.calls.isEmpty)

        await Self.until(timeout: 10) { vm.message != nil }
        #expect(log.ranOnMainThread == false, "`hermes config set` ran on the main actor")
        #expect(log.count(of: "config") >= 3)
        // Sequential `config set`, one key/value per spawn: `hermes config
        // set` takes exactly one pair at v2026.9.7 (`hermes_cli/config.py`
        // `_cmd_config_set`), so there is no batch form to collapse them into.
        // P39 put a `--` separator before the positionals: `config set -- <key> <value>`.
        #expect(log.calls.allSatisfy { $0.count == 5 && Array($0.prefix(3)) == ["config", "set", "--"] })
    }

    /// The sweep is the point: every platform form goes through the same
    /// `PlatformSetupForm.commitSave`, so a form left behind would show up
    /// here as a spawn on the main thread.
    @Test func everyPlatformSetupFormSavesOffTheMainActor() async {
        // One representative per config-writing shape: env+config (Discord,
        // Slack), env+config with a token migration (Ntfy), and config-only
        // (WhatsApp Cloud). Every form routes through the same
        // `PlatformSetupForm.commitSave`, so one left behind would show up
        // here as a spawn on the main thread.
        let ctx = Self.scratchContext()

        let discordLog = CLILog()
        let discord = DiscordSetupViewModel(context: ctx, cliRunner: discordLog.runner())
        let slackLog = CLILog()
        let slack = SlackSetupViewModel(context: ctx, cliRunner: slackLog.runner())
        let ntfyLog = CLILog()
        let ntfy = NtfySetupViewModel(context: ctx, cliRunner: ntfyLog.runner())
        let cloudLog = CLILog()
        let cloud = WhatsAppCloudSetupViewModel(context: ctx, cliRunner: cloudLog.runner())

        discord.save(); slack.save(); ntfy.save(); cloud.save()

        await Self.until(timeout: 15) {
            discord.message != nil && slack.message != nil
                && ntfy.message != nil && cloud.message != nil
        }
        for (name, log) in [("discord", discordLog), ("slack", slackLog),
                            ("ntfy", ntfyLog), ("whatsapp_cloud", cloudLog)] {
            #expect(log.count(of: "config") > 0, "\(name) never reached the CLI")
            #expect(log.ranOnMainThread == false, "\(name) spawned `hermes config set` on the main actor")
        }
    }

    /// The load half. `load()` is synchronous and must return BEFORE the
    /// `.env` / config.yaml reads happen — which is observable without any
    /// timing: the fields are still empty when it returns.
    @Test func telegramLoadDoesNotReadInline() async {
        let ctx = Self.scratchContext()
        try? "TELEGRAM_BOT_TOKEN=live-token\n".write(
            toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)

        let vm = TelegramSetupViewModel(context: ctx)
        vm.load(capabilities: .empty)
        #expect(vm.botToken.isEmpty, "the `.env` read happened inline on the main actor")
        #expect(vm.isLoading)

        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(vm.botToken == "live-token")
    }

    /// The regression the detachment introduces, and the guard that closes
    /// it: the form renders its pre-load BLANKS until the read lands, and
    /// `saveForm` treats a blank field as an `unset` — so a Save from there
    /// would comment live credentials out of `.env` (GW-F6 / DI L10 reached
    /// through the other door).
    @Test func saveIsRefusedWhileTheFirstLoadIsInFlight() async {
        let ctx = Self.scratchContext()
        try? "TELEGRAM_BOT_TOKEN=live-token\n".write(
            toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)

        let log = CLILog()
        let vm = TelegramSetupViewModel(context: ctx, cliRunner: log.runner())
        vm.load(capabilities: .empty)
        vm.save()   // user clicks Save before the load lands

        await Self.until(timeout: 10) { !vm.isLoading }
        #expect(log.calls.isEmpty, "a save ran against the pre-load blank form")
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("TELEGRAM_BOT_TOKEN=live-token"), "the blank save unset a live key")
        #expect(vm.botToken == "live-token")
    }

    // MARK: - 2. Gateway

    private static var v0211: HermesCapabilities {
        HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")
    }

    /// The five mutations called `ctx.runHermes(...)` directly, inheriting the
    /// silent 60 s default the `HermesCLIRunner` contract says every site must
    /// name — and bypassing the injected runner entirely, so no test could see
    /// them at all. With the fix reverted the fake runner records nothing.
    @Test func gatewayMutationsGoThroughTheRunnerWithANamedTimeout() async {
        let log = TimedCLILog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(), capabilities: .empty,
            // P40: the mutation verdict is judged by OUTPUT now, so a fake
            // that answers `("", 0)` is a refusal — and a refused start
            // reloads immediately instead of on the settle timer. Give the
            // fake `launchd_start`'s own success line
            // (`hermes_cli/gateway.py:3940` @ v2026.9.7).
            cliRunner: log.runner(output: "✓ Service started"))

        vm.startGateway()
        await Self.until(timeout: 10) { log.calls.count == 1 }
        #expect(log.calls.first?.args == ["gateway", "start"])
        #expect(log.calls.first?.timeout == MessagingGatewayViewModel.mutationTimeout)
        #expect(log.ranOnMainThread == false)

        await Self.until(timeout: 10) { vm.isBusy == false }
        vm.approvePairing(platform: "telegram", code: "ABC123")
        await Self.until(timeout: 10) { log.calls.contains { $0.args.first == "pairing" } }
        let pairing = log.calls.first { $0.args.first == "pairing" }
        #expect(pairing?.args == ["pairing", "approve", "--", "telegram", "ABC123"])
        #expect(pairing?.timeout == MessagingGatewayViewModel.mutationTimeout)
    }

    /// The third load probe (`gateway list`) went through the transport
    /// directly, so the P11/P17 coalescing and off-main tests could only ever
    /// see two of the three spawns a load makes.
    @Test func gatewayListProbeIsObservableThroughTheRunner() async {
        let log = TimedCLILog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(), capabilities: Self.v0211, cliRunner: log.runner())
        #expect(Self.v0211.hasGatewayList)

        vm.load(force: true)
        await Self.until(timeout: 15) { vm.isLoading == false }
        let list = log.calls.first { $0.args == ["gateway", "list"] }
        #expect(list != nil, "the `gateway list` probe is still invisible to the runner seam")
        #expect(list?.timeout == HermesGatewayListService.fetchTimeout)
        #expect(log.ranOnMainThread == false)
    }

    /// A load superseded by a mutation returned before clearing `isLoading`,
    /// so the spinner ran until the post-mutation reload landed.
    @Test func supersededLoadStillClearsTheSpinner() async {
        let log = TimedCLILog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(), capabilities: .empty, cliRunner: log.runner(delay: 0.2))

        vm.load(force: true)
        #expect(vm.isLoading)
        // A mutation invalidates the in-flight load's DATA without starting a
        // load of its own — the exact case the old guard leaked.
        vm.invalidateInFlightLoads()

        await Self.until(timeout: 15) { vm.isLoading == false }
        #expect(vm.isLoading == false, "a superseded load left the spinner up forever")
    }

    /// `GatewayView.attachCapabilitiesIfNeeded` replaces the whole VM on the
    /// first appear; the outgoing instance's DETACHED load kept running three
    /// CLI probes nobody would ever read.
    @Test func cancelLoadStopsTheRemainingProbes() async {
        let log = TimedCLILog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(), capabilities: Self.v0211, cliRunner: log.runner(delay: 0.3))

        vm.load(force: true)
        await Self.until(timeout: 10) { log.calls.count == 1 }
        vm.cancelLoad()
        #expect(vm.isLoading == false)

        // The cancelled load stops between probes, so it can never reach all
        // three. (One more may be in flight at the moment of cancellation.)
        try? await Task.sleep(for: .milliseconds(900))
        #expect(log.calls.count < 3, "the replaced view model ran its whole probe triple anyway")
    }

    // MARK: - 3. Kanban diagnostics throttle

    /// The 30 s throttle only advanced its stamp inside the SUCCESS branch, so
    /// a host where `kanban diagnostics --json` fails (a wedged ssh, a broken
    /// tenant) respawned it on every 5 s board tick — a spawn storm against a
    /// possibly-remote host.
    ///
    /// Driven through the production method `refresh()` itself calls, with a
    /// FAILING fetcher. With the stamp back inside the success branch this sees
    /// one attempt per tick instead of one per interval.
    @Test func failingDiagnosticsHostIsThrottledToOneAttempt() async {
        let vm = KanbanBoardViewModel(context: Self.scratchContext())
        vm.supportsDiagnostics = true

        var attempts = 0
        let failing: () async -> [String: [HermesKanbanDiagnostic]]? = {
            attempts += 1
            return nil    // what a failing `kanban diagnostics --json` yields
        }
        // Three board ticks inside the 30 s window.
        await vm.refreshDiagnosticsIfDue(failing)
        await vm.refreshDiagnosticsIfDue(failing)
        await vm.refreshDiagnosticsIfDue(failing)

        #expect(attempts == 1, "a failing diagnostics host spawned \(attempts) times in three ticks")
    }

    /// The throttle must not swallow a host that has no diagnostics support,
    /// and must still refetch once the window has passed. (The interval is a
    /// private constant, so the positive half is pinned on the first attempt
    /// after the flag is turned on — which also clears the stamp.)
    @Test func diagnosticsFetchIsSkippedWhenUnsupportedAndRearmsOnReenable() async {
        let vm = KanbanBoardViewModel(context: Self.scratchContext())
        var attempts = 0
        let counting: () async -> [String: [HermesKanbanDiagnostic]]? = {
            attempts += 1
            return [:]
        }

        await vm.refreshDiagnosticsIfDue(counting)
        #expect(attempts == 0, "diagnostics were fetched on a host that does not support them")

        vm.supportsDiagnostics = true
        await vm.refreshDiagnosticsIfDue(counting)
        #expect(attempts == 1)
        await vm.refreshDiagnosticsIfDue(counting)
        #expect(attempts == 1, "the throttle let a second attempt through inside the window")

        // Turning support off and on again clears the stamp, so the next tick
        // is due immediately — the board must repopulate, not wait 30 s.
        vm.supportsDiagnostics = false
        vm.supportsDiagnostics = true
        await vm.refreshDiagnosticsIfDue(counting)
        #expect(attempts == 2)
    }

    // MARK: - 4. MCP login

    /// `MCPLoginController.start` called `proc.run()` on the MainActor — a
    /// fork/exec, and on a remote context a whole `ssh` spawn.
    ///
    /// `Process` cannot be subclassed to record the calling thread (`NSTask`
    /// is abstract — overriding `run()` makes Foundation demand every
    /// primitive), so the assertion is on ORDER instead, which is just as
    /// deterministic: `run()` launches synchronously, so `isRunning` flips the
    /// instant it is called. A process that has not been launched by the time
    /// `start()` returns cannot have been launched ON the main actor, because
    /// the main actor has not suspended yet. The child blocks for 5 s so it
    /// cannot have exited instead.
    @Test func mcpLoginDoesNotSpawnBeforeStartReturns() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 5"]

        let controller = MCPLoginController(context: .local, makeLoginProcess: { _ in proc })
        controller.start(server: "example", flow: nil)
        #expect(proc.isRunning == false, "`Process.run()` happened inline on the main actor")
        #expect(controller.isRunning, "the sheet must show the run as live from the click")

        await Self.until(timeout: 10) { proc.isRunning }
        #expect(proc.isRunning, "the detached spawn never happened")
        controller.stop()
    }

    /// …and P21's EOF-then-judge verdict still holds across the move: the
    /// handlers are installed before the spawn, and the verdict comes from the
    /// emitter's own success line rather than the exit code.
    @Test func mcpLoginVerdictSurvivesTheDetachedSpawn() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "printf '✓ Authenticated with example\\n'; exit 0"]

        let controller = MCPLoginController(context: .local, makeLoginProcess: { _ in proc })
        controller.start(server: "example", flow: nil)

        await Self.until(timeout: 10) { controller.succeeded != nil }
        #expect(controller.succeeded == true)
        #expect(controller.isRunning == false)
        #expect(controller.output.contains("Authenticated"))
    }

    // MARK: - 5. The subprocess timeout primitive

    /// `dashboardListenerPID`'s `lsof` had a bare `waitUntilExit()` — an
    /// unbounded wait on the main actor. The bound now lives in one place.
    @Test func waitUntilExitHonoursItsTimeout() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 30"]
        try? proc.run()

        let started = Date()
        let exited = await Task.detached { proc.waitUntilExit(timeout: 0.5) }.value
        #expect(exited == false, "a `sleep 30` child was reported as exiting within 0.5 s")
        // The child is reaped, not orphaned.
        #expect(proc.isRunning == false)
        // Generous ceiling: this asserts the wait is BOUNDED, not its latency.
        #expect(Date().timeIntervalSince(started) < 20)
    }

    /// P29 · The overrun arm itself. The test above drives `sh -c "sleep 30"`,
    /// which obeys SIGTERM, so it never exercised the escalation — with the
    /// original `terminate(); waitUntilExit()` a child that IGNORES SIGTERM
    /// hung this call forever. `trap "" TERM` is that child.
    @Test func waitUntilExitEscalatesPastAChildThatIgnoresSIGTERM() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", #"trap "" TERM; sleep 30"#]
        try? proc.run()

        let started = Date()
        let exited = await Task.detached { proc.waitUntilExit(timeout: 0.5) }.value
        let elapsed = Date().timeIntervalSince(started)

        #expect(exited == false)
        // The point of the test: it RETURNED. With the bare `waitUntilExit()`
        // this never completes, because SIGTERM is trapped and `sleep 30` runs
        // its full half-minute. Well under that, and well over the poll budget.
        #expect(elapsed < 20, "the overrun path was unbounded (\(elapsed)s)")
        // SIGKILL cannot be trapped, so this child really is gone.
        #expect(proc.isRunning == false)
    }

    /// A process that exits on its own is reported as such.
    @Test func waitUntilExitReportsANormalExit() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 3"]
        try? proc.run()
        let exited = await Task.detached { proc.waitUntilExit(timeout: 10) }.value
        #expect(exited == true)
        #expect(proc.terminationStatus == 3)
    }

    // MARK: - 6. The sweep: no NEW synchronous wait on the main actor
    /// The roots the sweep walks, named once so the sweep and the
    /// existence check cannot drift apart.
    static let sweepRoots: [(path: String, defaultsToMainActor: Bool)] = [
        ("scarf/scarf", true),
        ("scarf/Scarf iOS", true),
        ("scarf/Packages/ScarfCore/Sources/ScarfCore", false),
        // Round-6 P53: the iOS runtime package was in NONE of the three C10
        // sweeps' roots — this one, `ProcessAsyncWaitP43cTests` and
        // `OffPoolDisciplineP52Tests` — so `CitadelServerTransport`'s
        // unbounded `semaphore.wait()` was invisible to all of them. It is a
        // SwiftPM library, not an app target, so nothing is main-actor by
        // default: `@MainActor` must be said, exactly like ScarfCore.
        ("scarf/Packages/ScarfIOS/Sources/ScarfIOS", false),
    ]

    /// P40's lesson, applied here: `FileManager.enumerator` returns `nil` for
    /// a missing root and the walk `continue`s past it in silence. A renamed
    /// target must break this test, not quietly halve the sweep.
    @Test("every root the sweep walks exists")
    func sweepRootsExist() throws {
        // Membership, not just existence: a root can be DELETED from the list
        // and every per-root floor below disappears with it, which is exactly
        // how ScarfIOS was absent without any test going red (round-6 P53).
        #expect(Self.sweepRoots.contains { $0.path == "scarf/Packages/ScarfIOS/Sources/ScarfIOS" },
                "the iOS runtime package is no longer swept")
        for (relative, _) in Self.sweepRoots {
            var isDir: ObjCBool = false
            let path = Self.repoRoot.appendingPathComponent(relative).path
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            #expect(exists && isDir.boolValue,
                    Comment(rawValue: "sweep root \(relative) is missing"))
        }
    }


    /// P37 finding 10. `waitDraining` / `waitUntilExit` are this codebase's
    /// two synchronous PROCESS waits, and both are C10 violations when they
    /// run on the main actor — `ProcessTimeout`'s cap bounds them, but a
    /// bounded 20 s block is still 20 s of a frozen window.
    ///
    /// The tests above each prove ONE site is off-main. This is the sweep: it
    /// finds every synchronous process wait whose enclosing function is
    /// main-actor-isolated and requires that set to be exactly the two
    /// documented, task-tracked allowances.
    ///
    /// **How isolation is decided, and why the obvious way is wrong.** The
    /// first draft of this test looked for a `@MainActor` line and gave up
    /// otherwise — which found exactly one file, because the app targets
    /// build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// (`project.pbxproj`), so in `scarf/scarf` and `Scarf iOS` EVERYTHING is
    /// main-actor-isolated and almost nothing says `@MainActor` anywhere. The
    /// test passed while `HealthViewModel.dashboardListenerPID` sat right
    /// there doing an `lsof` wait on the main actor. So: in a
    /// default-isolated target a wait is a hit UNLESS something on its
    /// declaration chain says `nonisolated`; in ScarfCore (no default
    /// isolation) it is a hit only when the type carries `@MainActor`.
    ///
    /// **No allowances left.** There were two. `HealthViewModel`
    /// `.dashboardListenerPID` (t-cd9fd829) went first: P38 replaced its
    /// hand-rolled drain with `waitDraining` and marked it `nonisolated`.
    /// `AppRelauncher.relaunch()` (t-b15ba4c3) went in round-4 P43 — the
    /// gesture's contract really is "this window is about to go away", but
    /// only AFTER `open(1)` succeeds, and a wedged `lsd` made that 20 s of
    /// frozen window instead. `relaunch()` is `nonisolated` and
    /// `ProfilesViewModel.switchAndRelaunch` calls it from its detached task,
    /// hopping back only for the verdict.
    ///
    /// An empty `allowed` takes the teeth out of the `isolatedScanned ==
    /// allowed.count` floor — zero equals zero however badly the matcher is
    /// broken — so the matcher is a named function now and
    /// `theSweepMatcherStillRecognisesEveryShape` plants one of each shape
    /// and checks it fires. That calibration, not the count, is what keeps
    /// this from passing vacuously.
    ///
    /// The "still REAL" check is now isolation-aware: it asserts the sweep
    /// ITSELF still reaches the allowed file's site (i.e. the site is still
    /// main-actor-isolated and un-opted-out), not merely that the string
    /// `waitDraining(` appears somewhere in it — which a `nonisolated` fix
    /// leaves true, so the check would have kept passing over dead debt.
    /// `allowed` carries each entry's path so a future allowance cannot be
    /// mis-mapped by an `if name == …` ladder.
    @Test func noNewSynchronousWaitRunsOnTheMainActor() throws {
        /// File basenames allowed to hold a main-actor-isolated sync wait,
        /// each with the task that will remove it. EMPTY, and adding to it is
        /// the thing this test exists to make hard.
        let allowed: [String: (path: String, task: String)] = [:]
        /// The primitives' own file. `ProcessTimeout.swift` IS the bounded,
        /// concurrently-drained wait every other site is supposed to call, so
        /// its internals are not a finding — and its `group.wait(` is the
        /// bounded drain grace, not a main-actor block.
        let primitivesFile = "ProcessTimeout.swift"
        /// Roots and whether the target defaults every declaration to the
        /// main actor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
        let roots = Self.sweepRoots

        var offenders: [String] = []
        var isolatedScanned = 0
        /// Every `.swift` file the enumeration actually opened, per root.
        /// `isolatedScanned == allowed.count` is `0 == 0` while `allowed` is
        /// empty, so an enumeration that read NOTHING — a renamed root, a
        /// `nil` enumerator, a `contentsOf` that threw for all of them — used
        /// to pass this test silently. The floor below is what makes "the
        /// sweep ran" a claim with evidence (round-4 P43b).
        var filesScannedByRoot: [String: Int] = [:]
        /// Basenames the sweep actually flagged — what makes an allowance
        /// verifiably still live, rather than "the string is in the file".
        var reachedByTheSweep: Set<String> = []

        for (relative, defaultsToMainActor) in roots {
            let root = Self.repoRoot.appendingPathComponent(relative)
            let files = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                Comment(rawValue: "\(relative) does not exist — the sweep would read nothing"))
            while let url = files.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                filesScannedByRoot[relative, default: 0] += 1
                let lines = src.components(separatedBy: "\n")

                // In ScarfCore, only an explicitly `@MainActor` type counts.
                let hasMainActorAttribute = lines.contains {
                    $0.trimmingCharacters(in: .whitespaces) == "@MainActor"
                }
                guard defaultsToMainActor || hasMainActorAttribute else { continue }

                guard url.lastPathComponent != primitivesFile else { continue }

                // Names bound to a `DispatchSemaphore` / `DispatchGroup` in
                // this file. A main-actor `sem.wait(…)` blocks the actor just
                // as hard as `waitUntilExit()` does — P38 added this shape
                // because `dashboardListenerPID`'s hand-rolled drain used
                // exactly it and the sweep only saw its `waitUntilExit`.
                var blockingWaiters: Set<String> = []
                for line in lines {
                    guard line.contains("DispatchSemaphore") || line.contains("DispatchGroup")
                    else { continue }
                    guard let eq = line.range(of: " = "),
                          let binding = line.range(of: "let ") ?? line.range(of: "var ")
                    else { continue }
                    let name = line[binding.upperBound..<eq.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !name.contains(" ") { blockingWaiters.insert(name) }
                }

                for (index, line) in lines.enumerated() {
                    guard Self.isSynchronousWait(
                        at: index, in: lines, blockingWaiters: blockingWaiters) else { continue }
                    let bare = line.trimmingCharacters(in: .whitespaces)

                    // Walk OUT to the enclosing declarations by indent. Only
                    // a line indented strictly less than everything seen so
                    // far encloses this one, so this visits the real chain
                    // and nothing else. Two mistakes this replaces: reading
                    // the nearest `func` landed on a NESTED helper (`func
                    // closePipes` inside a `nonisolated func unzip`) and
                    // reported three already-opted-out sites as hits; then
                    // scanning every line above it found a `nonisolated`
                    // hundreds of lines away on an unrelated member and
                    // silently excused a real one.
                    var optedOut = false
                    var minIndent = Self.indent(of: line)
                    // P38: a MULTI-LINE signature meant the walk landed on the
                    // signature's closing `) throws -> String {` — same indent
                    // as the `private nonisolated static func` line that opens
                    // it — and then refused to look at that line, because it
                    // was not strictly less indented. Two already-`nonisolated`
                    // helpers were reported as offenders. While the enclosing
                    // line has not yet been recognised as a declaration START,
                    // keep walking at the SAME indent.
                    var needDeclarationStart = false
                    let declarationStarts = ["func ", "var ", "init(", "subscript",
                                             "class ", "struct ", "enum ", "extension "]
                    var i = index - 1
                    while i >= 0 {
                        let candidate = lines[i]
                        defer { i -= 1 }
                        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        let indent = Self.indent(of: candidate)
                        if needDeclarationStart {
                            guard indent <= minIndent else { continue }
                        } else {
                            guard indent < minIndent else { continue }
                        }
                        minIndent = indent
                        if trimmed.contains("nonisolated") { optedOut = true; break }
                        // A `Thread.detachNewThread { … }` body is not the
                        // main actor, whatever the enclosing declaration says
                        // — a fresh thread has no actor at all. It is the
                        // primitive `Process.waitDrainingAsync` and
                        // `SpotifyAuthFlow.reapDetached` both use, precisely
                        // because `Task.detached` (which the walk correctly
                        // does NOT treat as an opt-out, since it stays on the
                        // cooperative pool) would not do. Added in round-5
                        // P48, when `HermesProxyService.stop()` gained a
                        // bounded escalation on one.
                        if trimmed.contains("Thread.detachNewThread") { optedOut = true; break }
                        needDeclarationStart = !declarationStarts.contains { trimmed.contains($0) }
                            && !trimmed.hasPrefix("//")
                        // Column 0 with a body brace: we have left the type.
                        if indent == 0, !needDeclarationStart { break }
                    }
                    guard !optedOut else { continue }

                    isolatedScanned += 1
                    let name = url.lastPathComponent
                    reachedByTheSweep.insert(name)
                    guard allowed[name] == nil else { continue }
                    offenders.append("\(name):\(index + 1) — \(bare)")
                }
            }
        }

        // The premise floor. Real counts at the time of writing: 299 + 50 +
        // 210 = 559 `.swift` files. The floor is deliberately well under that
        // so ordinary growth or a deleted feature cannot trip it, and well
        // over zero so a broken enumeration cannot hide.
        // Per-root floors, because the roots are not the same size: ScarfIOS
        // is a 14-file package, so a shared `> 20` would have made the floor
        // itself the thing that failed the day it was added (round-6 P53).
        let floors: [String: Int] = [
            "scarf/scarf": 20,
            "scarf/Scarf iOS": 20,
            "scarf/Packages/ScarfCore/Sources/ScarfCore": 20,
            "scarf/Packages/ScarfIOS/Sources/ScarfIOS": 5,
        ]
        for (relative, _) in roots {
            let floor = floors[relative] ?? 20
            #expect((filesScannedByRoot[relative] ?? 0) > floor,
                    Comment(rawValue: "the sweep read \(filesScannedByRoot[relative] ?? 0)"
                            + " Swift files under \(relative) (floor \(floor))"))
        }
        let filesScanned = filesScannedByRoot.values.reduce(0, +)
        #expect(filesScanned > 450, """
            The sweep read only \(filesScanned) Swift files. It cannot have \
            covered the three roots, so neither the offender list nor the \
            count below means anything.
            """)

        #expect(isolatedScanned == allowed.count, """
            The sweep found \(isolatedScanned) main-actor-isolated synchronous \
            process wait(s) and there are \(allowed.count) allowance(s). If \
            the count is LOWER the gate has stopped matching and this test is \
            no longer a check; if higher, see `offenders`.
            """)
        #expect(offenders.isEmpty, Comment(rawValue: """
            A synchronous process wait runs on the main actor (charter C10). \
            Move it off-main (see `PlatformSetupHelpers.detached`) or, if it \
            genuinely must block the gesture, add it to `allowed` with the \
            task that will remove it: \(offenders.joined(separator: "; "))
            """))

        // Each allowance must still be REAL, judged by ISOLATION rather than
        // by a substring: the sweep above must have reached it. A site fixed
        // by marking it `nonisolated` still contains `waitDraining(`, so the
        // old substring check kept passing over debt that no longer existed —
        // which is exactly what happened to the `HealthViewModel.swift` entry.
        for (name, entry) in allowed {
            let url = Self.repoRoot.appendingPathComponent(entry.path)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    Comment(rawValue: "\(name) moved — fix `allowed`'s path (\(entry.task))"))
            #expect(
                reachedByTheSweep.contains(name),
                Comment(rawValue: "\(name) is no longer a main-actor-isolated synchronous wait"
                        + " — drop it from `allowed` and close \(entry.task)")
            )
        }
    }

    /// Every synchronous wait shape this sweep recognises, as one named
    /// predicate so the calibration test below can plant each shape and watch
    /// it fire. With `allowed` empty the `isolatedScanned == allowed.count`
    /// floor is 0 == 0 — true no matter how broken the matcher is — so this
    /// is the only thing standing between the sweep and a vacuous pass.
    ///
    /// `waitDraining` and `waitUntilExit` are the process primitives. The
    /// other two are how a main-actor caller blocks on work it handed to
    /// another thread, which is the same C10 violation in different clothes:
    /// an `isRunning` spin, or a `wait(` on a semaphore or a group bound in
    /// the same file (`blockingWaiters`).
    // MARK: - The login-shell environment probe (round-6 P58)

    /// Five main-actor sites resolved `HermesFileService.enrichedEnvironment()`
    /// inline: `SpotifyAuthFlow.start`, `OAuthFlowController.defaultProcess`,
    /// `MCPLoginController.defaultProcess`, `HealthViewModel`'s dashboard
    /// spawn and `HermesProxyService.start`.
    ///
    /// It is not a `Process` WAIT, so ``isSynchronousWait(at:in:blockingWaiters:)``
    /// never looked at it — but C10's first clause is "never block the main
    /// actor on process spawns", and this is two `zsh` probes at 5 s + 3 s
    /// behind a `swift_once`. `scarfApp` warms it on a detached task at
    /// launch; a main-actor reader that arrives while that warm-up is still
    /// running BLOCKS on the once-token, so the cost lands on the click that
    /// opens a sign-in sheet. `NousAuthFlow` was fixed for exactly this in
    /// `c93c2287` and its four twins were not, which is the "idle twin"
    /// lesson one more time.
    ///
    /// Separate from the wait sweep rather than another needle in it,
    /// because the OPT-OUTS differ: for a blocking wait `Task.detached` is
    /// deliberately NOT an opt-out (it leaves the pool question to the P52
    /// sweep), while for "is this on the main actor" it plainly is.
    @Test func noMainActorShellEnvProbe() throws {
        /// Basenames allowed to read it on the main actor, each with the task
        /// that will remove it.
        let allowed: [String: (path: String, task: String)] = [
            "ChatViewModel.swift": (
                "scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift",
                "t-406d56d6 — `launchTerminal(arguments:)` reads it for the "
                + "remote terminal's SSH_AUTH_SOCK. Found by this sweep on the "
                + "run that introduced it, outside P58's named scope; the "
                + "function is synchronous and its callers are not, so the fix "
                + "is a split like `SpotifyAuthFlow`'s, not a hoist."
            ),
            "scarfApp.swift": (
                "scarf/scarf/scarfApp.swift",
                "Not a call: two CLOSURES handed to `SSHTransport"
                + ".environmentEnricher` / `LocalTransport.environmentEnricher`, "
                + "invoked later by the transports on whatever thread is doing "
                + "the spawn. No task — there is nothing to fix."
            ),
        ]

        var offenders: [String] = []
        var reached: Set<String> = []
        var filesScanned = 0

        for (relative, defaultsToMainActor) in Self.sweepRoots {
            let root = Self.repoRoot.appendingPathComponent(relative)
            let files = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                Comment(rawValue: "\(relative) does not exist"))
            while let url = files.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                filesScanned += 1
                let lines = src.components(separatedBy: "\n")
                let hasMainActorAttribute = lines.contains {
                    $0.trimmingCharacters(in: .whitespaces) == "@MainActor"
                }
                guard defaultsToMainActor || hasMainActorAttribute else { continue }
                for (index, line) in lines.enumerated() {
                    guard Self.isMainActorShellEnvProbe(at: index, in: lines) else { continue }
                    let name = url.lastPathComponent
                    reached.insert(name)
                    guard allowed[name] == nil else { continue }
                    offenders.append(
                        "\(name):\(index + 1) — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(filesScanned > 450, Comment(rawValue:
            "the sweep read only \(filesScanned) Swift files — it cannot have covered the roots"))
        #expect(offenders.isEmpty, Comment(rawValue: """
            `HermesFileService.enrichedEnvironment()` is resolved on the main \
            actor (charter C10): it is a `swift_once` over two `zsh` probes at \
            5 s + 3 s, so a reader that beats the launch warm-up freezes the \
            window for up to eight seconds. Hoist it through `OffPool.run` \
            before the spawn, as `NousAuthFlow.start()` does: \
            \(offenders.joined(separator: "; "))
            """))
        let stale = Set(allowed.keys).subtracting(reached)
        #expect(stale.isEmpty, Comment(rawValue:
            "allowed file(s) no longer match — drop them from `allowed`: "
            + stale.sorted().joined(separator: ", ")))
    }

    /// A main-actor-isolated read of the login-shell environment.
    ///
    /// Not a hit when the line ITSELF carries the hop (`OffPool.run { … }`,
    /// `Task.detached`, `Thread.detachNewThread`) — that is the cure, and a
    /// sweep whose first report is the fix is a sweep nobody reads (round-6
    /// P53's lesson, one file over) — nor when the enclosing chain carries
    /// one, nor on the declaration itself.
    static func isMainActorShellEnvProbe(at index: Int, in lines: [String]) -> Bool {
        let line = lines[index]
        guard line.contains("enrichedEnvironment()") else { return false }
        let bare = line.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("//") { return false }
        if bare.contains("func enrichedEnvironment") { return false }
        for hop in Self.offActorHops where line.contains(hop) { return false }

        // Same indent walk as the wait sweep, with `Task.detached` and
        // `OffPool.run` added to the opt-outs: both leave the main actor,
        // which is the only question this test asks.
        var minIndent = Self.indent(of: line)
        var needDeclarationStart = false
        let declarationStarts = ["func ", "var ", "init(", "subscript",
                                 "class ", "struct ", "enum ", "extension "]
        var i = index - 1
        while i >= 0 {
            let candidate = lines[i]
            defer { i -= 1 }
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = Self.indent(of: candidate)
            if needDeclarationStart {
                guard indent <= minIndent else { continue }
            } else {
                guard indent < minIndent else { continue }
            }
            minIndent = indent
            if trimmed.contains("nonisolated") { return false }
            for hop in Self.offActorHops where trimmed.contains(hop) { return false }
            needDeclarationStart = !declarationStarts.contains { trimmed.contains($0) }
                && !trimmed.hasPrefix("//")
            if indent == 0, !needDeclarationStart { break }
        }
        return true
    }

    /// The three spellings that take work off the main actor.
    static let offActorHops = ["OffPool.run", "Task.detached", "Thread.detachNewThread"]

    /// Planted shapes, so the matcher above is a check rather than a claim.
    @Test func theShellEnvMatcherIsCalibrated() {
        let cured = """
            func start() {
                startTask = Task { [weak self] in
                    let env = await OffPool.run { HermesFileService.enrichedEnvironment() }
                    self?.launch(localEnvironment: env)
                }
            }
            """.components(separatedBy: "\n")
        for i in cured.indices {
            #expect(!Self.isMainActorShellEnvProbe(at: i, in: cured),
                    Comment(rawValue: "the cure is reported as the defect: \(cured[i])"))
        }

        let broken = """
            func start() {
                var env = HermesFileService.enrichedEnvironment()
                env["PYTHONUNBUFFERED"] = "1"
            }
            """.components(separatedBy: "\n")
        #expect(broken.indices.contains { Self.isMainActorShellEnvProbe(at: $0, in: broken) },
                "the matcher misses the inline main-actor read — it checks nothing")

        let hoisted = """
            nonisolated func probe() {
                let env = HermesFileService.enrichedEnvironment()
            }
            """.components(separatedBy: "\n")
        for i in hoisted.indices {
            #expect(!Self.isMainActorShellEnvProbe(at: i, in: hoisted),
                    "`nonisolated` is still an opt-out")
        }

        // The multi-line hop: the call is a line BELOW `Task.detached {`.
        let detached = """
            func warm() {
                Task.detached {
                    _ = HermesFileService.enrichedEnvironment()
                }
            }
            """.components(separatedBy: "\n")
        for i in detached.indices {
            #expect(!Self.isMainActorShellEnvProbe(at: i, in: detached),
                    "a detached closure is off the main actor, whatever P52 says about the pool")
        }
    }

    static func isSynchronousWait(
        at index: Int, in lines: [String], blockingWaiters: Set<String>
    ) -> Bool {
        let line = lines[index]
        let isProcessWait = line.contains("waitDraining(")
            || line.contains(".waitUntilExit(")
        // A `while p.isRunning { Thread.sleep(…) }` spin is a synchronous
        // wait with extra steps. A loop that SUSPENDS instead (`try? await
        // Task.sleep`) is not — it hands the actor back on every turn, which
        // is the whole point — so the BODY decides, not the condition.
        let pollBody = lines[index..<min(index + 4, lines.count)].joined(separator: "\n")
        let isRunningPoll = line.contains(".isRunning")
            && (line.contains("while ") || line.contains("repeat"))
            && (pollBody.contains("Thread.sleep") || pollBody.contains("usleep("))
        let isWaiterBlock = line.contains(".wait(")
            && blockingWaiters.contains { line.contains($0 + ".wait(") }
        guard isProcessWait || isRunningPoll || isWaiterBlock else { return false }
        // The primitives' own declarations, and comments about them.
        if line.contains("func waitDraining") || line.contains("func waitUntilExit") { return false }
        let bare = line.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("//") || bare.hasPrefix("///") { return false }
        return true
    }

    /// Plant one of each shape and one of each near-miss. If a refactor ever
    /// narrows the matcher, this fails here rather than letting the sweep
    /// report a clean repo it never actually looked at.
    @Test func theSweepMatcherStillRecognisesEveryShape() {
        func matches(_ source: String, waiters: Set<String> = ["sem", "group"]) -> Bool {
            let lines = source.components(separatedBy: "\n")
            return (0..<lines.count).contains {
                Self.isSynchronousWait(at: $0, in: lines, blockingWaiters: waiters)
            }
        }

        // The two process primitives.
        #expect(matches("        proc.waitUntilExit(timeout: 5)"))
        #expect(matches("        let r = proc.waitDraining(timeout: 5, pipes: [p])"))
        // The hand-rolled spin (P38 item 23).
        #expect(matches("""
                while proc.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            """))
        #expect(matches("""
                while proc.isRunning {
                    usleep(20_000)
                }
            """))
        // The hand-off blocks (P38 item 23).
        #expect(matches("        sem.wait(timeout: .now() + 2)"))
        #expect(matches("        group.wait(timeout: .now() + 2)"))

        // Near misses that must NOT fire, so the sweep stays usable.
        #expect(!matches("        // proc.waitUntilExit(timeout: 5)"))
        #expect(!matches("        /// See ``Process.waitDraining(timeout:pipes:)``."))
        #expect(!matches("    func waitDraining(timeout: TimeInterval) -> Bool {"))
        // A loop that SUSPENDS hands the actor back every turn.
        #expect(!matches("""
                while proc.isRunning {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            """))
        // A `.wait(` on something this file never bound to a semaphore.
        #expect(!matches("        other.wait(timeout: .now() + 2)"))
    }

    // MARK: - Helpers

    /// Like P11's `CLILog` but keeps each call's TIMEOUT too — P22's gateway
    /// findings are as much about the cap each site names as about where it
    /// runs.
    final class TimedCLILog: @unchecked Sendable {
        struct Call: Sendable { let args: [String]; let timeout: TimeInterval }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _ranOnMainThread = false

        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
        var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return _ranOnMainThread }

        func runner(delay: TimeInterval = 0, output: String = "") -> HermesCLIRunner {
            { [self] args, timeout in
                let onMain = Thread.isMainThread
                lock.lock()
                _ranOnMainThread = _ranOnMainThread || onMain
                _calls.append(Call(args: args, timeout: timeout))
                lock.unlock()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                return (output, 0)
            }
        }
    }
}
