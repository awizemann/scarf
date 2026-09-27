import Testing
import Foundation
@testable import scarf
import ScarfCore

/// P7f — cron Run Now / selection / `--pin`, and peer run / drafts. The
/// view models are driven through their injected CLI runners, so each test
/// fails if its wiring is reverted, not just its helper.
@MainActor
@Suite struct HermesP7fCronPeersTests {

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [(args: [String], timeout: TimeInterval)] = []
        func append(_ args: [String], _ timeout: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            _items.append((args, timeout))
        }
        var items: [(args: [String], timeout: TimeInterval)] {
            lock.lock(); defer { lock.unlock() }
            return _items
        }
        func all(_ prefix: [String]) -> [(args: [String], timeout: TimeInterval)] {
            items.filter { Array($0.args.prefix(prefix.count)) == prefix }
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private nonisolated static func timeoutText(_ seconds: TimeInterval) -> String {
        TransportError.timeout(seconds: seconds, partialStdout: Data()).errorDescription ?? ""
    }

    // MARK: - (1)/(2) cron run verdicts — literal `_job_action` output

    /// `_job_action` + `_run_outcome` (`hermes_cli/cron.py:789-809` @
    /// v2026.9.24) for a paused job: green line, exit 0, skip sentence.
    @Test func pausedAndMissingSkipsAreRefusalsNotStarts() {
        for sentence in ["Job is paused/disabled; resume it before running.",
                         "Job no longer exists; nothing to run."] {
            let output = "Triggered job: Nightly (j1)\n  Next run: 2026-09-27T09:00:00+00:00\n  \(sentence)\n"
            let verdict = CronViewModel.runNowVerdict(exitCode: 0, output: output)
            #expect(verdict == .refused(sentence))
            let message = CronViewModel.runNowMessage(verdict)
            #expect(message.outcome == .failure)
            #expect(message.text.contains(sentence))
        }
    }

    @Test func alreadyFiringIsUnconfirmed() {
        for sentence in ["Job is already being fired by the scheduler; not run again.",
                         "Already being fired by the scheduler; not run again."] {
            let verdict = CronViewModel.runNowVerdict(exitCode: 0, output: "Triggered job: N (j1)\n  \(sentence)\n")
            #expect(verdict == .alreadyRunning(sentence))
            #expect(CronViewModel.runNowMessage(verdict).outcome == .unconfirmed)
        }
    }

    /// The non-skip arms: a synchronous success, and the three "started"
    /// shapes — v0.17's mark-due line (v2026.6.19:316), a background
    /// dispatch, and a relay-fronted forward (no `job` in the result, so the
    /// name falls back to the id and `_run_outcome({})` prints the tick line).
    @Test func successArms() {
        #expect(CronViewModel.runNowVerdict(exitCode: 0, output: "Triggered job: N (j1)\n  Ran now: succeeded.\n") == .ran)
        for output in ["Triggered job: Digest (digest-1)\n  It will run on the next scheduler tick.\n",
                       "Triggered job: j1 (j1)\n  It will run on the next scheduler tick.\n",
                       "Triggered job: Digest (digest-1)\n  Running in background.\n",
                       "Triggered job: Digest (digest-1)\n"] {
            let verdict = CronViewModel.runNowVerdict(exitCode: 0, output: output)
            #expect(verdict == .started, "\(output)")
            // C1: the pre-v0.18 toast is byte-identical.
            let message = CronViewModel.runNowMessage(verdict)
            #expect(message.text == "Agent started — dashboard will update when it finishes")
            #expect(message.outcome == .success)
        }
        #expect(CronViewModel.runNowMessage(.ran).outcome == .success)
    }

    /// Only Scarf's OWN cap is "still running"; any other -1 or a CLI
    /// failure keeps the failure it always was.
    @Test func onlyScarfsOwnTimeoutIsStillRunning() {
        let cap = CronViewModel.runNowTimeout
        #expect(CronViewModel.runNowVerdict(exitCode: -1, output: Self.timeoutText(cap)) == .stillRunning)
        // `runHermesCLI` prefixes whatever the child printed before the kill.
        #expect(CronViewModel.runNowVerdict(exitCode: -1, output: "partial\n" + Self.timeoutText(cap)) == .stillRunning)
        #expect(CronViewModel.runNowMessage(.stillRunning).outcome == .unconfirmed)
        if case .failed = CronViewModel.runNowVerdict(exitCode: -1, output: Self.timeoutText(30)) {} else {
            Issue.record("another cap's sentence is not ours")
        }
        if case .failed = CronViewModel.runNowVerdict(exitCode: -1, output: "") {} else {
            Issue.record("a missing binary is a failure")
        }
        if case .failed = CronViewModel.runNowVerdict(exitCode: 0, output: "Triggered job: N (j1)\n  Ran now: failed.\n") {} else {
            Issue.record("Ran now: failed. stays a failure")
        }
    }

    // MARK: - (1) runNow wiring: the cap, the timeout verdict, the tick

    @Test func runNowUsesTheLongCapAndReadsATimeoutAsUnconfirmed() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = CronViewModel(context: home.context, mutationRunner: { args, timeout in
            calls.append(args, timeout)
            if args.starts(with: ["cron", "run"]) {
                return (TransportError.timeout(seconds: timeout, partialStdout: Data()).errorDescription ?? "", -1)
            }
            return ("", 0)
        })
        let job = HermesCronJob(id: "j1", name: "Nightly", prompt: "p", model: nil,
                                schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                                enabled: true, state: "scheduled")
        vm.runNow(job)
        await Self.settle { !vm.isRunningNow(job) && vm.message != "Running \"Nightly\"…" }
        let run = try #require(calls.all(["cron", "run"]).first)
        #expect(run.args == ["cron", "run", "j1"])
        #expect(run.timeout == CronViewModel.runNowTimeout)
        #expect(run.timeout >= 300, "a synchronous agent run must not be killed at 30 s")
        #expect(vm.messageOutcome == .unconfirmed)
        #expect(vm.message == CronViewModel.runNowMessage(.stillRunning).text)
        // S08-F1: a timed-out run marked nothing due, so no follow-up tick
        // (it used to tick after every verdict and fire every other due job).
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(calls.all(["cron", "tick"]).isEmpty)
    }

    /// P9 (t-d6384e2e item 8): `cron run` is a whole synchronous agent run
    /// since v0.18.0, so the click posts an immediate unconfirmed
    /// "Running…", and a second click while it is in flight starts nothing.
    @Test func runNowPostsRunningAndIgnoresASecondClickInFlight() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        let vm = CronViewModel(context: home.context, mutationRunner: { args, timeout in
            calls.append(args, timeout)
            if args.starts(with: ["cron", "run"]) {
                gate.wait()
                return ("Triggered job: Nightly (j1)\n  Ran now: succeeded.\n", 0)
            }
            return ("", 0)
        })
        let job = HermesCronJob(id: "j1", name: "Nightly", prompt: "p", model: nil,
                                schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                                enabled: true, state: "scheduled")
        vm.runNow(job)
        #expect(vm.message == "Running \"Nightly\"…")
        #expect(vm.messageOutcome == .unconfirmed)
        #expect(vm.isRunningNow(job))
        await Self.settle { calls.all(["cron", "run"]).count == 1 }
        vm.runNow(job)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(calls.all(["cron", "run"]).count == 1, "a second click started a second run")

        gate.signal()
        await Self.settle { !vm.isRunningNow(job) }
        #expect(!vm.isRunningNow(job))
        #expect(vm.message == CronViewModel.runNowMessage(.ran).text)
    }

    // MARK: - S08-F1: the follow-up `cron tick` only where it is needed

    private static let tickJob = HermesCronJob(
        id: "j1", name: "Nightly", prompt: "p", model: nil,
        schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
        enabled: true, state: "scheduled")

    /// Drive a real Run Now against a runner that answers `cron run` with
    /// `output`/`exit`, and return every call it saw once the run (and any
    /// tick) has settled.
    private static func runNowCalls(
        output: String, exit: Int32, hostNeedsTick: Bool?
    ) async throws -> Calls {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = CronViewModel(context: home.context, mutationRunner: { args, timeout in
            calls.append(args, timeout)
            if args.starts(with: ["cron", "run"]) { return (output, exit) }
            return ("", 0)
        })
        // `nil`: leave the view model as it is before the version probe
        // answers.
        if let hostNeedsTick { vm.hostNeedsRunNowTick = hostNeedsTick }
        vm.runNow(tickJob)
        await settle { !vm.isRunningNow(tickJob) }
        // The tick is sent 250 ms after the verdict; wait past that so an
        // unwanted tick has had every chance to show up.
        for _ in 0..<100 {
            if !calls.all(["cron", "tick"]).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return calls
    }

    /// A v0.17 host (`v2026.6.19` `_job_action` :316) only marks the job
    /// due, so the tick is what fires it — unchanged from before (C1).
    @Test func preV018StartedRunStillTicks() async throws {
        let calls = try await Self.runNowCalls(
            output: "Triggered job: Nightly (j1)\n  It will run on the next scheduler tick.\n",
            exit: 0, hostNeedsTick: true)
        #expect(calls.all(["cron", "tick"]).count == 1)
        #expect(calls.all(["cron", "tick"]).first?.timeout == 300)
    }

    /// v0.18+: the job already ran; a tick would fire every other due job.
    @Test func v018RanRunDoesNotTick() async throws {
        let calls = try await Self.runNowCalls(
            output: "Triggered job: Nightly (j1)\n  Ran now: succeeded.\n",
            exit: 0, hostNeedsTick: false)
        #expect(calls.all(["cron", "run"]).count == 1)
        #expect(calls.all(["cron", "tick"]).isEmpty)
    }

    /// v0.18+ relay-fronted job: prints the old next-tick line, but the
    /// running gateway owns it — still no tick.
    @Test func v018RelayForwardDoesNotTick() async throws {
        let calls = try await Self.runNowCalls(
            output: "Triggered job: j1 (j1)\n  It will run on the next scheduler tick.\n",
            exit: 0, hostNeedsTick: false)
        #expect(calls.all(["cron", "tick"]).isEmpty)
    }

    /// A failed run marked nothing due on any host, so ticking would only
    /// fire OTHER jobs.
    @Test func failedRunDoesNotTickEvenOnAnOldHost() async throws {
        let calls = try await Self.runNowCalls(
            output: "Failed to run job: Job 'j1' not found\n",
            exit: 1, hostNeedsTick: true)
        #expect(calls.all(["cron", "tick"]).isEmpty)
    }

    @Test func tickDecisionMatrix() {
        let verdicts: [CronViewModel.RunNowVerdict] = [
            .ran, .started, .refused("x"), .alreadyRunning("x"), .stillRunning, .failed("x"),
        ]
        let startedLine = "Triggered job: N (j1)\n  It will run on the next scheduler tick.\n"
        for verdict in verdicts {
            #expect(!CronViewModel.shouldTickAfterRunNow(verdict, output: startedLine, hostNeedsTick: false), "\(verdict)")
            #expect(CronViewModel.shouldTickAfterRunNow(verdict, output: startedLine, hostNeedsTick: true)
                    == (verdict == .started), "\(verdict)")
        }
        // A `Ran now:` line proves a synchronous host, whatever the flag says.
        #expect(!CronViewModel.shouldTickAfterRunNow(
            .started, output: "Triggered job: N (j1)\n  Ran now: failed.\n", hostNeedsTick: true))
    }

    /// Before the version probe answers the view model is told nothing, and
    /// an unknown host gets no tick (a v0.18+ host would fire every due job).
    @Test func unprobedHostDoesNotTick() async throws {
        let calls = try await Self.runNowCalls(
            output: "Triggered job: j1 (j1)\n  It will run on the next scheduler tick.\n",
            exit: 0, hostNeedsTick: nil)
        #expect(calls.all(["cron", "run"]).count == 1)
        #expect(calls.all(["cron", "tick"]).isEmpty)
    }

    // MARK: - S08-F3: the Mac rows name the host zone

    /// `.env`'s HERMES_TIMEZONE outranks config `timezone`, as Hermes loads
    /// it (`hermes_cli/env_loader.py:397-398`, `hermes_time.py:83-106`).
    @Test func schedulePhraseNamesTheHostZoneFromEnvThenConfig() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try "timezone: Pacific/Kiritimati\n".write(
            to: home.url.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let job = HermesCronJob(id: "j1", name: "N", prompt: "p", model: nil,
                                schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                                enabled: true, state: "scheduled")

        let vm = CronViewModel(context: home.context, mutationRunner: { _, _ in ("", 0) })
        vm.load(force: true)
        await Self.settle { vm.scheduleZoneNote != nil }
        #expect(vm.schedulePhrase(for: job) == "Daily at 9 AM (Pacific/Kiritimati)")

        try "export HERMES_TIMEZONE=\"Pacific/Chatham\"\n".write(
            to: home.url.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        vm.load(force: true)
        await Self.settle { vm.scheduleZoneNote == "Pacific/Chatham" }
        #expect(vm.schedulePhrase(for: job) == "Daily at 9 AM (Pacific/Chatham)")
    }

    // MARK: - (3) selection race

    private static func writeJobs(_ home: TempHermesHome, _ jobs: String) throws {
        let url = URL(fileURLWithPath: home.context.paths.cronJobsJSON)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"jobs": [\#(jobs)]}"#.utf8).write(to: url)
    }

    private static func jobJSON(_ id: String, model: String? = nil) -> String {
        let modelField = model.map { #", "model": "\#($0)""# } ?? ""
        return #"{"id": "\#(id)", "name": "\#(id)", "prompt": "p", "enabled": true, "state": "scheduled", "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"}\#(modelField)}"#
    }

    /// A load started for A must not snap the selection back to A after the
    /// user clicked B while it was in flight.
    @Test func loadDoesNotOverwriteANewerSelection() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.writeJobs(home, Self.jobJSON("a") + "," + Self.jobJSON("b"))
        let vm = CronViewModel(context: home.context, mutationRunner: { _, _ in ("", 0) })
        vm.load(force: true)
        await Self.settle { !vm.isLoading && vm.jobs.count == 2 }
        let a = try #require(vm.jobs.first { $0.id == "a" })
        let b = try #require(vm.jobs.first { $0.id == "b" })
        vm.selectedJob = a
        vm.load(force: true)
        // Synchronously, before the load's main-actor hop can run.
        vm.selectJob(b)
        await Self.settle { !vm.isLoading }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(vm.selectedJob?.id == "b")
    }

    // MARK: - (8) `--pin` that did not take

    private static let pinSupport = CronViewModel.EditorSupport(
        workdir: true, noAgent: true, failureDeliver: true, modelPin: true)

    private func createWithPin(storedModel: String?) async throws -> CronViewModel {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try Self.writeJobs(home, Self.jobJSON("abc123", model: storedModel))
        let vm = CronViewModel(context: home.context, mutationRunner: { args, _ in
            // `cron_create`'s own lines (`hermes_cli/cron.py:712-713` @ v2026.9.24).
            args.starts(with: ["cron", "create"])
                ? ("Created job: abc123\n  Name: Nightly\n  Schedule: 0 9 * * *\n", 0)
                : ("", 0)
        })
        var form = CronJobEditor.FormState()
        form.name = "Nightly"
        form.schedule = "0 9 * * *"
        form.prompt = "summarize"
        form.pinModel = true
        vm.createJob(from: form, support: Self.pinSupport)
        await Self.settle { vm.message != nil && vm.pendingPinCheck == nil && !vm.isLoading }
        try await Task.sleep(nanoseconds: 50_000_000)
        return vm
    }

    @Test func pinWithNoMainModelWarnsAfterReload() async throws {
        let vm = try await createWithPin(storedModel: nil)
        #expect(vm.message == CronViewModel.pinDidNotTakeMessage)
        #expect(vm.messageOutcome == .failure)
    }

    @Test func pinThatTookStaysQuiet() async throws {
        let vm = try await createWithPin(storedModel: "gpt-5")
        #expect(vm.message == "Job created")
        #expect(vm.messageOutcome == .success)
    }

    @Test func pinCheckOnlyArmsForARealPinFlag() {
        let create = CronViewModel.createJobArguments(
            schedule: "0 9 * * *", prompt: "--pin", name: "", deliver: "", skills: [],
            script: "", repeatCount: "")
        // "--pin" as the PROMPT positional is not the flag.
        #expect(CronViewModel.pinCheckTarget(arguments: create, output: "Created job: x") == nil)
        let pinned = CronViewModel.createJobArguments(
            schedule: "0 9 * * *", prompt: "p", name: "", deliver: "", skills: [],
            script: "", repeatCount: "", pinModel: true)
        #expect(CronViewModel.pinCheckTarget(arguments: pinned, output: "o") == .createdFrom(output: "o"))
        #expect(CronViewModel.pinCheckTarget(arguments: ["cron", "edit", "--pin", "--", "j9"], output: "") == .job(id: "j9"))
        #expect(CronViewModel.pinCheckTarget(arguments: ["cron", "edit", "--unpin", "--", "j9"], output: "") == nil)
        #expect(CronViewModel.createdJobID(in: "\u{1B}[32mCreated job: abc123\u{1B}[0m\n  Name: x") == "abc123")
    }

    // MARK: - (5)/(6) peers

    private func peersViewModel(
        _ home: TempHermesHome, calls: Calls,
        reply: @escaping @Sendable ([String], TimeInterval) -> (Int32, String, String)
    ) -> PeersViewModel {
        let vm = PeersViewModel(context: home.context, dmRunner: { args, timeout in
            calls.append(args, timeout)
            return reply(args, timeout)
        })
        vm.peers = [HermesBotPeer(name: "spark", url: "http://spark.lan:8377")]
        vm.selectedPeerName = "spark"
        vm.composeText = "long task"
        return vm
    }

    private static func key(in args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--idempotency-key"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private nonisolated static let runOK = #"{"peer": "spark", "profile": null, "session_id": "s", "run_id": "run_1", "status": "started", "idempotency_key": "k", "replayed": false}"#

    /// A retry of the same message after a Scarf-side timeout reuses the key,
    /// so the peer replays the run it may already have created.
    @Test func peerRunRetryReusesTheKeyUntilASuccess() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        final class Mode: @unchecked Sendable { var fail = true }
        let mode = Mode()
        let vm = peersViewModel(home, calls: calls) { _, timeout in
            mode.fail ? (-1, "", Self.timeoutText(timeout)) : (0, Self.runOK, "")
        }
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 1 }
        let first = try #require(calls.all(["peer", "run"]).first)
        #expect(first.timeout == HermesPeerCLI.runProcessTimeout)
        #expect(first.timeout >= 150)
        let key1 = try #require(Self.key(in: first.args))
        #expect(vm.composeText == "long task", "a failure keeps the text")

        mode.fail = false
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 2 }
        #expect(Self.key(in: calls.items[1].args) == key1)
        #expect(vm.runs.first?.id == "run_1")

        vm.composeText = "long task"
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 3 }
        #expect(Self.key(in: calls.items[2].args) != key1, "a new run after a success gets a new key")
    }

    /// P9 (t-d6384e2e item 6): only a failure that may have created the
    /// run keeps its key. An HTTP rejection is the peer answering — the key
    /// is reserved only after admission (`api_server_runs.py:626-675` @
    /// v2026.9.24) — and a kept key after a `409 idempotency_key_conflict`
    /// (fingerprint includes the Bot Chat `session_id`, `:593-596`) would
    /// hit the same 409 on every retry of that text. "Could not reach peer"
    /// is where the POST's own urllib timeout lands (`peer.py:325-329`), so
    /// that one stays ambiguous and keeps the key. Stderr literals are
    /// `_peer_failure`'s (`peer.py:209-212`).
    @Test(arguments: [
        ("Peer 'spark' rejected the request (HTTP 409): Idempotency-Key was already used with a different request payload", false),
        ("Peer 'spark' rejected the request (HTTP 400): Missing 'input' field", false),
        ("Could not reach peer 'spark': timed out", true),
        ("Could not reach peer 'spark': <urlopen error [Errno 61] Connection refused>", true),
    ])
    func peerRunKeyIsKeptOnlyWhenTheRunMayExist(_ stderr: String, keeps: Bool) async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = peersViewModel(home, calls: calls) { _, _ in (1, "", stderr) }
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 1 }
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 2 }
        let key1 = try #require(Self.key(in: calls.items[0].args))
        let key2 = try #require(Self.key(in: calls.items[1].args))
        #expect((key1 == key2) == keeps, "stderr: \(stderr)")
    }

    /// A different message never inherits the pending key.
    @Test func peerRunKeyIsBoundToTheMessage() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = peersViewModel(home, calls: calls) { _, timeout in (-1, "", Self.timeoutText(timeout)) }
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 1 }
        vm.composeText = "another task"
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 2 }
        #expect(Self.key(in: calls.items[0].args) != Self.key(in: calls.items[1].args))
    }

    /// A finished run / DM must not clear a draft typed while it ran.
    @Test func finishedCallsKeepADraftTypedMeanwhile() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = peersViewModel(home, calls: calls) { args, _ in
            Thread.sleep(forTimeInterval: 0.2)
            return args.starts(with: ["peer", "run"])
                ? (0, Self.runOK, "")
                : (0, #"{"peer": "spark", "profile": null, "session_id": "s", "reply": "hi"}"#, "")
        }
        vm.startRun()
        vm.composeText = "next message"
        await Self.settle { !vm.isSending && calls.items.count == 1 }
        #expect(vm.composeText == "next message")

        vm.composeText = "dm text"
        vm.sendDM(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)"))
        vm.composeText = "typed during the dm"
        await Self.settle { !vm.isSending && calls.items.count == 2 }
        #expect(vm.composeText == "typed during the dm")

        // Unchanged → still cleared, as before.
        vm.composeText = "plain"
        vm.startRun()
        await Self.settle { !vm.isSending && calls.items.count == 3 }
        #expect(vm.composeText.isEmpty)
    }

    // MARK: - (7) a11y

    @Test func composeEditorIsLabelledAsTheMessageField() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(
            contentsOf: root.appendingPathComponent("scarf/Features/Peers/Views/PeersView.swift"),
            encoding: .utf8)
        let editor = try #require(code.range(of: "TextEditor(text: $viewModel.composeText)"))
        let tail = code[editor.upperBound...]
        let label = try #require(tail.range(of: ".accessibilityLabel("))
        #expect(tail[label.upperBound...].hasPrefix("\"Message\")"))
    }
}
