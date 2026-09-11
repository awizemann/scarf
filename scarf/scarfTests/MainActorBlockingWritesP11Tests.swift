import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase P11 of the whole-surface audit (charter C10: "never block the main
/// actor on process spawns … and every subprocess has a timeout").
///
/// Two invariants, both driven through the `HermesCLIRunner` seam so a fake
/// `hermes` can sleep or count:
///
/// 1. A Settings write (`hermes config set/unset`, `hermes memory off`,
///    `hermes config check/migrate`) returns to the main actor immediately
///    and runs the spawn off it — and concurrent writes are serialised so the
///    second one cannot land between the first's write and the first's
///    config re-read.
/// 2. `MessagingGatewayViewModel.load(changeToken:)` coalesces: N ticks
///    carrying the same file-watcher token produce ONE in-flight load, not N
///    triples of `gateway status` / `pairing list` / `gateway list`.
///
/// **Why these tests are honest** (see memory note "A @MainActor suite cannot
/// test detached-read interleaving"). Measuring the elapsed time of the
/// synchronous `vm.setSetting(...)` call itself proves NOTHING: the kick-off
/// is `Task { … }` on a MainActor-isolated class, and that body cannot start
/// until the caller returns — so the call is fast whether or not the spawn
/// inside it blocks the main actor. Both timing tests below were first
/// written that way, and both passed with the detached hop deleted.
///
/// What they assert instead is where the fake `hermes` actually RAN: the
/// runner records `Thread.isMainThread`, which is `true` exactly when the
/// spawn executed on the main actor and `false` when it went through the
/// `Task.detached` hop. That is deterministic and load-independent — a
/// wall-clock latency budget was tried first and flaked under the full
/// parallel test run, where other suites' main-actor work inflates it. With
/// the detached hop deleted from `enqueueConfigWrite`, `runConfigCheck` or
/// `MessagingGatewayViewModel.load`, every one of these tests fails.
/// The coalescing test is count-based and needs no timing either: dropping
/// the change-token guard makes it see one probe triple per tick.
@Suite("P11 — Settings writes and Gateway loads stay off the main actor")
@MainActor
struct MainActorBlockingWritesP11Tests {

    /// Thread-safe recorder for a fake `hermes` runner. The closure is
    /// `@Sendable` and runs on a detached executor, so every field is behind
    /// a lock.
    final class CLILog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        /// (enter, exit) wall-clock stamps per invocation, in start order.
        private var _spans: [(Date, Date)] = []
        private var _ranOnMainThread = false

        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
        var spans: [(Date, Date)] { lock.lock(); defer { lock.unlock() }; return _spans }
        /// True if ANY invocation executed on the main thread — i.e. the
        /// spawn was made from the main actor, which charter C10 forbids.
        var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return _ranOnMainThread }
        func count(of verb: String) -> Int {
            calls.filter { $0.first == verb }.count
        }

        /// A runner that records the argv, sleeps `delay`, and returns
        /// `output` with exit 0.
        func runner(delay: TimeInterval = 0, output: String = "") -> HermesCLIRunner {
            { [self] args, _ in
                let start = Date()
                let onMain = Thread.isMainThread
                lock.lock(); _ranOnMainThread = _ranOnMainThread || onMain
                _calls.append(args); let slot = _spans.count
                _spans.append((start, start)); lock.unlock()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                lock.lock(); _spans[slot] = (start, Date()); lock.unlock()
                return (output, 0)
            }
        }
    }

    /// An isolated Hermes home so `loadConfig()` / `readText` touch a temp
    /// dir and never the developer's real `~/.hermes`.
    private static func scratchContext() -> ServerContext {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p11-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return .local(home: home)
    }

    // MARK: - 1. Settings writes

    /// The decisive C10 assertion: a fake `hermes` that blocks for a full
    /// second must not hold the main actor for it. See the suite comment for
    /// why the assertion is where the spawn ran rather than how long the
    /// (always-fast) synchronous call took.
    @Test func settingsWriteDoesNotBlockTheMainActor() async {
        let log = CLILog()
        let vm = SettingsViewModel(context: Self.scratchContext(), cliRunner: log.runner(delay: 0.2))

        vm.setSetting("display.streaming", value: "true")
        // Nothing has been committed yet — the CLI has not even been reached.
        #expect(vm.message == nil)

        await Self.until(timeout: 10) { log.count(of: "config") == 1 }
        #expect(log.ranOnMainThread == false, "`hermes config set` ran on the main actor")
        #expect(log.calls.first == ["config", "set", "--", "display.streaming", "true"])
    }

    /// `hermes memory off` (the non-`config set` branch of
    /// `setMemoryProvider`) rides the same off-main chain.
    @Test func memoryProviderOffDoesNotBlockTheMainActor() async {
        let log = CLILog()
        let vm = SettingsViewModel(context: Self.scratchContext(), cliRunner: log.runner(delay: 0.2))

        vm.setMemoryProvider("")

        await Self.until(timeout: 10) { log.count(of: "memory") == 1 }
        #expect(log.ranOnMainThread == false, "`hermes memory off` ran on the main actor")
        #expect(log.calls.first == ["memory", "off"])
    }

    /// Two quick toggles must not run their CLI writes concurrently: each
    /// write is `set` + `re-read config.yaml`, and an overlapping second
    /// write commits a snapshot under the wrong banner. Non-overlapping
    /// spans is the observable form of that guarantee.
    @Test func rapidTogglesAreSerialised() async {
        let log = CLILog()
        let vm = SettingsViewModel(context: Self.scratchContext(), cliRunner: log.runner(delay: 0.3))

        vm.setSetting("display.streaming", value: "true")
        vm.setSetting("display.markdown", value: "false")

        // Wait for both invocations to have RUN TO COMPLETION — a span whose
        // exit stamp still equals its entry stamp is one that has only
        // started, and comparing against it would make the overlap check
        // vacuously true.
        // Generous: under the full parallel `scarfTests` run the two detached
        // hops can take far longer than 10 s to be scheduled, and this wait
        // is only ever exhausted on the failure path.
        await Self.until(timeout: 120) {
            log.spans.count == 2 && log.spans.allSatisfy { $0.1 > $0.0 }
        }
        let spans = log.spans
        // `guard`, not a bare subscript: indexing `spans[1]` after a
        // count mismatch traps and takes the WHOLE test host down with it,
        // cascading into every suite still running (seen under load).
        guard spans.count == 2, log.calls.count == 2 else {
            Issue.record("expected 2 serialised config writes, saw \(spans.count) spans / \(log.calls.count) calls")
            return
        }
        #expect(spans.allSatisfy { $0.1 > $0.0 })
        // Second invocation started only after the first returned.
        #expect(spans[1].0 >= spans[0].1, "config writes overlapped — the chain is not serialising")
        // Order is preserved: first enqueued, first run.
        // P39: `config set -- <key> <value>`, so the key is index 3.
        #expect(log.calls[0].count == 5 && log.calls[0][3] == "display.streaming")
        #expect(log.calls[1].count == 5 && log.calls[1][3] == "display.markdown")
    }

    /// `config check` / `config migrate` are now `async`, so the Advanced
    /// tab's buttons can't freeze the window. Proven the same way: the call
    /// suspends rather than blocking, so a main-actor statement between the
    /// kick-off and the await runs while the fake CLI sleeps.
    @Test func configDiagnosticsRunOffTheMainActor() async {
        let log = CLILog()
        let vm = SettingsViewModel(
            context: Self.scratchContext(),
            cliRunner: log.runner(delay: 0.2, output: "✓ Config is valid")
        )

        let output = await vm.runConfigCheck()
        #expect(log.ranOnMainThread == false, "`hermes config check` ran on the main actor")
        #expect(output == "✓ Config is valid")
        #expect(log.calls == [["config", "check"]])
    }

    /// The LOW finding attached to this phase: a write refreshed `config`
    /// but left `rawConfigYAML` (the Advanced tab's raw editor) and
    /// `personalities` showing pre-write content until a manual Reload.
    @Test func successfulWriteRefreshesRawYAMLAndPersonalities() async {
        let ctx = Self.scratchContext()
        let yaml = """
        personality: pirate
        personalities:
          pirate:
            prompt: Arr
          scholar:
            prompt: Indeed
        """
        try? yaml.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)

        let log = CLILog()
        // P39: the write is OUTPUT-judged, so the fake must print the
        // emitter's own success line (`hermes_cli/config.py:3521`) — an empty
        // stdout at exit 0 is now a refusal, which is the whole point.
        let vm = SettingsViewModel(
            context: ctx,
            cliRunner: log.runner(output: "✓ Set personality = scholar in \(ctx.paths.configYAML)")
        )
        #expect(vm.rawConfigYAML.isEmpty)

        vm.setSetting("personality", value: "scholar")
        await Self.until(timeout: 5) { !vm.rawConfigYAML.isEmpty }

        #expect(vm.rawConfigYAML.contains("personalities:"))
        #expect(vm.personalities.contains("pirate"))
        #expect(vm.personalities.contains("scholar"))
    }

    // MARK: - 2. Gateway load coalescing

    /// N rapid file-watcher ticks carrying the SAME change token must
    /// produce one in-flight load. `gateway_state.json` is rewritten far
    /// more often than its contents matter, and each uncoalesced load spawned
    /// three CLI invocations against a possibly-remote host.
    @Test func rapidTicksProduceOneGatewayLoad() async {
        let log = CLILog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(),
            capabilities: .empty,
            cliRunner: log.runner(delay: 0.3)
        )

        let token = Date()
        for _ in 0..<8 { vm.load(changeToken: token) }

        await Self.until(timeout: 10) { vm.isLoading == false }
        // One load = one `gateway status` + one `pairing list`.
        #expect(log.count(of: "gateway") == 1, "expected one gateway status probe, got \(log.count(of: "gateway"))")
        #expect(log.count(of: "pairing") == 1)

        // A repeat of the settled token is still a no-op…
        vm.load(changeToken: token)
        #expect(log.count(of: "gateway") == 1)

        // …but a genuinely new change, and any forced reload, still loads.
        vm.load(changeToken: token.addingTimeInterval(1))
        await Self.until(timeout: 10) { log.count(of: "gateway") == 2 }
        vm.load(force: true)
        await Self.until(timeout: 10) { log.count(of: "gateway") == 3 }
    }

    /// The gateway load's own C10 assertion: `load()` is synchronous and must
    /// return before the probes run.
    @Test func gatewayLoadDoesNotBlockTheMainActor() async {
        let log = CLILog()
        let vm = MessagingGatewayViewModel(
            context: Self.scratchContext(),
            capabilities: .empty,
            cliRunner: log.runner(delay: 0.2)
        )

        vm.load()
        // Synchronous kick-off: the spinner is up and no probe has run.
        #expect(vm.isLoading == true)
        #expect(log.calls.isEmpty)

        await Self.until(timeout: 15) { vm.isLoading == false }
        #expect(log.ranOnMainThread == false, "the gateway probes ran on the main actor")
        #expect(log.count(of: "gateway") == 1)
    }

    // MARK: - Helpers

    /// Poll `condition` off the hot path until true or `timeout` elapses.
    /// Deliberately not a `Task.sleep`-free spin: the whole point is to let
    /// the detached work make progress.
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
