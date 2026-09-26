import Testing
import Foundation
@testable import scarf
import ScarfCore

/// P5b — call-site tests for the v0.21.4/v0.21.5 CLI outcome wiring. Every
/// earlier test for these fixes called a static helper, so reverting the
/// view-model wiring left them green. These drive the view models through
/// their injected CLI runner and assert what reached the CLI and the UI.
@MainActor
@Suite struct HermesP5bCallSiteTests {
    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0214 = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")

    /// Records every `(args, timeout)` a fake runner receives.
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
        /// The first recorded call whose argv starts with `prefix`.
        func first(_ prefix: [String]) -> (args: [String], timeout: TimeInterval)? {
            items.first { Array($0.args.prefix(prefix.count)) == prefix }
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - (1) Peers: sendDM passes the timeout; a Scarf-side kill

    private func peersViewModel(
        _ home: TempHermesHome, reply: @escaping @Sendable ([String], TimeInterval) -> (Int32, String, String),
        calls: Calls
    ) -> PeersViewModel {
        let vm = PeersViewModel(context: home.context, dmRunner: { args, timeout in
            calls.append(args, timeout)
            let (code, out, err) = reply(args, timeout)
            return (code, out, err)
        })
        vm.peers = [HermesBotPeer(name: "spark", url: "http://spark.lan:8377")]
        vm.selectedPeerName = "spark"
        vm.composeText = "hello"
        return vm
    }

    @Test func sendDMPassesTheCapabilityTimeout() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        for (caps, expected) in [(Self.v0214, HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0214)),
                                 (Self.v0213, TimeInterval(600))] {
            let calls = Calls()
            let vm = peersViewModel(home, reply: { _, _ in
                (0, #"{"peer": "spark", "profile": null, "session_id": "s", "reply": "hi"}"#, "")
            }, calls: calls)
            vm.sendDM(capabilities: caps)
            await Self.settle { !vm.isSending }
            let call = try #require(calls.first(["peer", "dm"]))
            #expect(call.timeout == expected)
            #expect(call.args == HermesPeerCLI.dmArgs(target: "spark", message: "hello"))
            #expect(vm.lastReply == "hi")
        }
        #expect(HermesPeerCLI.dmProcessTimeout(capabilities: Self.v0214) == 720)
    }

    /// v0.21.4+: Scarf's own cap firing clears the compose box and reads as
    /// unconfirmed — the peer may already hold the message.
    @Test func localTimeoutOnV0214IsUnconfirmedAndClearsCompose() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        // Exactly what `runHermesCLISplit` returns for a TransportError.timeout.
        let vm = peersViewModel(home, reply: { _, timeout in
            (-1, "", TransportError.timeout(seconds: timeout, partialStdout: Data()).errorDescription ?? "")
        }, calls: calls)
        vm.sendDM(capabilities: Self.v0214)
        await Self.settle { !vm.isSending }
        #expect(vm.composeText.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(vm.messageIsUnconfirmed)
        #expect(!vm.messageIsFailure)
        #expect(vm.message == PeersViewModel.dmLocalTimeoutText(target: "spark"))
    }

    /// C1: v0.21.3 keeps the failure (and the text) it always had.
    @Test func localTimeoutBelowV0214StaysAFailure() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = peersViewModel(home, reply: { _, timeout in
            (-1, "", TransportError.timeout(seconds: timeout, partialStdout: Data()).errorDescription ?? "")
        }, calls: calls)
        vm.sendDM(capabilities: Self.v0213)
        await Self.settle { !vm.isSending }
        #expect(vm.composeText == "hello")
        #expect(vm.errorMessage == "Command timed out after 600s.")
        #expect(vm.message == nil)
    }

    // MARK: - (6) Profiles: delete uses the settlement warning

    static let settlementPendingOutput = """
        ✓ Removed /Users/me/.hermes/profiles/bot1
        Profile 'bot1' deleted.
        Error: Profile 'bot1' was deleted, but its session/routing identity settlement is still pending — run: hermes profile purge-identity bot1
        """

    @Test func profilesDeleteReportsSettlementPendingAsCompleted() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = ProfilesViewModel(context: home.context, cliRunner: { args, timeout in
            calls.append(args, timeout)
            if args.starts(with: ["profile", "delete"]) { return (Self.settlementPendingOutput, 1) }
            return ("", 0)
        })
        vm.delete(HermesProfile(name: "bot1", isActive: false, path: "/tmp/bot1"))
        await Self.settle { vm.message != nil }
        #expect(calls.first(["profile", "delete"])?.args == ["profile", "delete", "-y", "--", "bot1"])
        #expect(vm.message == ProfilesViewModel.completedWithWarning(
            String(localized: "Deleted bot1"),
            warning: "Profile 'bot1' was deleted, but its session/routing identity settlement is still pending — run: hermes profile purge-identity bot1"))
    }

    // MARK: - (5)/(6) Health: optimize refusal → canForce, only-Scarf, --force

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// `held_store_refusal` (`hermes_state_holders.py:502-514` @ v2026.9.24).
    static func refusal(holders: [String]) -> String {
        (["Refusing `hermes sessions optimize`: another process is using /Users/me/.hermes/state.db."]
         + holders.map { "  \($0)" }
         + ["Rewriting the database under a live writer is how every agent ends up refusing turns with the retired state.db-wal error. Nothing is lost.",
            "Stop them first (`hermes gateway stop`, quit the Desktop app, pause cron), then re-run.",
            "Override with --force if you accept the risk.",
            "Recovery guide: https://hermes-agent.nousresearch.com/docs/user-guide/session-storage-recovery"])
            .joined(separator: "\n")
    }

    private func runOptimize(
        caps: HermesCapabilities, output: String, force: Bool = false, calls: Calls
    ) async -> HealthViewModel {
        let vm = HealthViewModel(context: .local, capabilities: caps, optimizeRunner: { args, timeout in
            calls.append(args, timeout)
            return (output, 1)
        })
        vm.runSessionsOptimize(force: force)
        await Self.settle { !vm.isRunningSessionsOptimize }
        return vm
    }

    @Test func refusalSetsCanForceOnlyWhereForceParses() async {
        let output = Self.refusal(holders: ["PID 4242 (hermes gateway run): state.db, state.db-wal"])
        let on = await runOptimize(caps: Self.v0214, output: output, calls: Calls())
        #expect(on.sessionsOptimizeCanForce)
        #expect(!on.sessionsOptimizeForceIsOnlyScarf)
        let off = await runOptimize(caps: Self.v0213, output: output, calls: Calls())
        #expect(!off.sessionsOptimizeCanForce)
        #expect(!off.sessionsOptimizeForceIsOnlyScarf)
    }

    @Test func onlyScarfsOwnReaderGetsTheLightPath() async {
        let own = "PID \(Self.ownPID) (scarf): state.db"
        let vm = await runOptimize(caps: Self.v0214, output: Self.refusal(holders: [own]), calls: Calls())
        #expect(vm.sessionsOptimizeCanForce)
        #expect(vm.sessionsOptimizeForceIsOnlyScarf)
        #expect(vm.sessionsOptimizeMessage?.contains("The only holder is Scarf's own read-only view") == true)

        // A `cannot prove` line or any foreign holder keeps the risk dialog.
        for extra in ["cannot prove the database is quiet (holder scan incomplete: uninspectable pid 9)",
                      "PID 4242 (hermes gateway run): state.db"] {
            let mixed = await runOptimize(
                caps: Self.v0214, output: Self.refusal(holders: [own, extra]), calls: Calls())
            #expect(mixed.sessionsOptimizeCanForce)
            #expect(!mixed.sessionsOptimizeForceIsOnlyScarf, "\(extra)")
        }
    }

    @Test func forcedRunAppendsForceOnlyOnV0214() async throws {
        let calls = Calls()
        _ = await runOptimize(caps: Self.v0214, output: "", force: true, calls: calls)
        #expect(try #require(calls.items.first).args == ["sessions", "optimize", "--force"])
        let older = Calls()
        _ = await runOptimize(caps: Self.v0213, output: "", force: true, calls: older)
        #expect(try #require(older.items.first).args == ["sessions", "optimize"])
    }

    @Test func anotherScarfCopyIsNamedByProcessName() {
        let text = HealthViewModel.sessionsOptimizeRefusalSummary(
            holders: ["PID 9001 (scarf): state.db"], isLocal: true, canForce: true, ownPID: 1)
        #expect(text.contains("Another Scarf window or copy"))
        #expect(!text.contains("The only holder is Scarf's own"))
        // Not every "scarf…" program is Scarf.
        #expect(!HealthViewModel.isOtherScarfHolder("PID 9001 (scarf-projects-mcp): state.db", ownPID: 1))
        #expect(!HealthViewModel.isOtherScarfHolder("PID 1 (scarf): state.db", ownPID: 1))
        #expect(HealthViewModel.isOtherScarfHolder("PID 9001 (Scarf -NSDocumentRevisionsDebugMode YES): state.db", ownPID: 1))
    }

    // MARK: - (6) Cron editor → view model: pinModel, wasModelPinned, !noAgent

    private func cronViewModel(_ home: TempHermesHome, calls: Calls) -> CronViewModel {
        CronViewModel(context: home.context, mutationRunner: { args, timeout in
            calls.append(args, timeout)
            return ("", 0)
        })
    }

    private static let allSupport = CronViewModel.EditorSupport(
        workdir: true, noAgent: true, failureDeliver: true, modelPin: true)

    private static func form(pin: Bool, noAgent: Bool = false) -> CronJobEditor.FormState {
        var form = CronJobEditor.FormState()
        form.name = "Nightly"
        form.schedule = "0 9 * * *"
        form.prompt = "summarize"
        form.pinModel = pin
        form.noAgent = noAgent
        return form
    }

    private func createArgs(_ form: CronJobEditor.FormState, support: CronViewModel.EditorSupport) async throws -> [String] {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = cronViewModel(home, calls: calls)
        vm.createJob(from: form, support: support)
        await Self.settle { calls.first(["cron", "create"]) != nil }
        return try #require(calls.first(["cron", "create"])).args
    }

    @Test func createPassesPinOnlyWhenSupportedAndAgentBacked() async throws {
        let pinned = try await createArgs(Self.form(pin: true), support: Self.allSupport)
        let pin = try #require(pinned.firstIndex(of: "--pin"))
        #expect(pin < (pinned.firstIndex(of: "--") ?? .max))

        // !noAgent guard: a script-only job never gets `--pin`.
        let script = try await createArgs(Self.form(pin: true, noAgent: true), support: Self.allSupport)
        #expect(!script.contains("--pin"))
        #expect(script.contains("--no-agent"))

        // Older host: stripped even though the form says pin.
        var older = Self.allSupport
        older.modelPin = false
        #expect(try await !createArgs(Self.form(pin: true), support: older).contains("--pin"))
    }

    private static func job(model: String?) -> HermesCronJob {
        HermesCronJob(id: "job1", name: "Nightly", prompt: "summarize", model: model,
                      schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                      enabled: true, state: "scheduled")
    }

    private func editArgs(
        _ job: HermesCronJob, _ form: CronJobEditor.FormState, support: CronViewModel.EditorSupport = allSupport
    ) async throws -> [String] {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = cronViewModel(home, calls: calls)
        vm.updateJob(job, from: form, support: support)
        await Self.settle { calls.first(["cron", "edit"]) != nil }
        return try #require(calls.first(["cron", "edit"])).args
    }

    @Test func editSendsUnpinFromTheSeededPin() async throws {
        let pinnedJob = Self.job(model: "gpt-5")
        // wasModelPinned comes from the JOB: turning the toggle off unpins.
        #expect(try await editArgs(pinnedJob, Self.form(pin: false)).contains("--unpin"))
        // Unchanged pin → nothing sent.
        let same = try await editArgs(pinnedJob, Self.form(pin: true))
        #expect(!same.contains("--pin") && !same.contains("--unpin"))
        // Unpinned job, toggle on → --pin.
        #expect(try await editArgs(Self.job(model: nil), Self.form(pin: true)).contains("--pin"))
        // No-agent job: the toggle is hidden, so nothing is sent.
        let script = try await editArgs(pinnedJob, Self.form(pin: false, noAgent: true))
        #expect(!script.contains("--pin") && !script.contains("--unpin"))
        // Older host: nothing either.
        var older = Self.allSupport
        older.modelPin = false
        let old = try await editArgs(pinnedJob, Self.form(pin: false), support: older)
        #expect(!old.contains("--pin") && !old.contains("--unpin"))
    }

    /// The view hands the form to these methods rather than re-deriving the
    /// argv itself — so the tests above cover what the editor really sends.
    @Test func cronViewDelegatesTheSaveToTheViewModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(
            contentsOf: root.appendingPathComponent("scarf/Features/Cron/Views/CronView.swift"),
            encoding: .utf8)
        #expect(code.components(separatedBy: "viewModel.createJob(from: form, support: editorSupport)").count == 3)
        #expect(code.contains("viewModel.updateJob(job, from: form, support: editorSupport)"))
        #expect(!code.contains("pinModel: hasCronModelPin"))
    }
}
