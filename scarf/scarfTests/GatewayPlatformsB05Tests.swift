import Testing
import Foundation
@testable import scarf
import ScarfCore

// B05 — blind re-audit S07 (gateway & platforms). Each suite names its
// finding; Hermes citations are @ v2026.9.24 unless stated.

private func scratchContext(_ tag: String) -> ServerContext {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scarf-b05-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return .local(home: home)
}

private func until(timeout: TimeInterval, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Records every argv and answers per verb.
private final class ScriptedCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    let answer: @Sendable ([String]) -> (String, Int32)
    init(_ answer: @escaping @Sendable ([String]) -> (String, Int32)) { self.answer = answer }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var runner: HermesCLIRunner {
        { [self] args, _ in
            lock.lock(); _calls.append(args); lock.unlock()
            return answer(args)
        }
    }
}

// MARK: - S07-F1 Slack: no inert reply_to_mode

@Suite("B05 · S07-F1 Slack writes no reply_to_mode")
@MainActor
struct SlackReplyModeB05Tests {
    @Test func theSaveBatchCarriesNoReplyToMode() async {
        let ctx = scratchContext("slack")
        let cli = ScriptedCLI { _ in ("✓ Set", 0) }
        let vm = SlackSetupViewModel(context: ctx, cliRunner: cli.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        vm.botToken = "xoxb-test"
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        let keys = cli.calls.compactMap { $0.last == nil ? nil : $0 }
            .filter { $0.starts(with: ["config", "set"]) }
            .map { $0.count >= 4 ? $0[3] : "" }
        #expect(!keys.contains { $0.contains("reply_to_mode") }, "\(keys)")
        #expect(keys.contains("platforms.slack.extra.reply_in_thread"), "premise: the save ran: \(cli.calls)")
    }
}

// MARK: - S07-F2 / F7 WhatsApp

@Suite("B05 · S07-F2/F7 WhatsApp reply prefix presence and mode default")
@MainActor
struct WhatsAppB05Tests {

    private func loaded(env: String, config: String) async -> WhatsAppSetupViewModel {
        let ctx = scratchContext("wa")
        try? env.write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? config.write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = WhatsAppSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        return vm
    }

    /// The finding's scenario: a user who only changes the allowlist must not
    /// write `reply_prefix: ""`, which turns Hermes's self-chat header off.
    @Test func aBlankPrefixOverAnAbsentKeyWritesNothing() async {
        let vm = await loaded(env: "WHATSAPP_ENABLED=true\nWHATSAPP_MODE=self-chat\n",
                              config: "whatsapp:\n  unauthorized_dm_behavior: pair\n")
        #expect(vm.replyPrefixInConfig == false)
        vm.allowedUsers = "15551234567"
        let plan = vm.savePlan()
        #expect(plan.config["whatsapp.reply_prefix"] == nil)
        #expect(plan.config["whatsapp.unauthorized_dm_behavior"] == "pair")
    }

    /// A deliberate empty prefix (header off) is kept, and a typed one written.
    @Test func aPresentKeyIsWrittenAsShown() async {
        let vm = await loaded(env: "", config: "whatsapp:\n  reply_prefix: \"\"\n")
        #expect(vm.replyPrefixInConfig)
        #expect(vm.replyPrefix == "")
        #expect(vm.savePlan().config["whatsapp.reply_prefix"] == "")

        let fresh = await loaded(env: "", config: "")
        fresh.replyPrefix = "[bot] "
        #expect(fresh.savePlan().config["whatsapp.reply_prefix"] == "[bot] ")
    }

    /// PyYAML loads `~`/`null` as None — the same as absent to Hermes.
    @Test func nullIsAbsent() {
        #expect(!WhatsAppSetupViewModel.replyPrefixIsSet(rawConfigText: "whatsapp:\n  reply_prefix: ~\n"))
        #expect(!WhatsAppSetupViewModel.replyPrefixIsSet(rawConfigText: "whatsapp:\n  reply_prefix: null\n"))
        #expect(!WhatsAppSetupViewModel.replyPrefixIsSet(rawConfigText: "whatsapp:\n  enabled: true\n"))
        #expect(!WhatsAppSetupViewModel.replyPrefixIsSet(rawConfigText: nil))
        #expect(WhatsAppSetupViewModel.replyPrefixIsSet(rawConfigText: "whatsapp:\n  reply_prefix: ''\n"))
        #expect(WhatsAppSetupViewModel.replyPrefixIsSet(rawConfigText: "whatsapp:\n  reply_prefix: hi\n"))
    }

    /// "Use Hermes Default" removes the key with `config unset`, on hosts
    /// that have the verb; below the floor it refuses with the hint.
    @Test func useDefaultUnsetsTheKey() async {
        let ctx = scratchContext("wa-unset")
        try? "whatsapp:\n  reply_prefix: \"\"\n".write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { args in
            args.starts(with: ["config", "unset"]) ? ("✓ Unset whatsapp.reply_prefix from /tmp/config.yaml", 0) : ("", 0)
        }
        let vm = WhatsAppSetupViewModel(context: ctx, cliRunner: cli.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }

        vm.useDefaultReplyPrefix(capabilities: .empty)
        #expect(vm.messageIsFailure, "below the v0.19 floor the verb is not shelled")
        #expect(!cli.calls.contains { $0.starts(with: ["config", "unset"]) })

        vm.useDefaultReplyPrefix(capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)"))
        await until(timeout: 10) { !vm.isSaving }
        #expect(cli.calls.contains(["config", "unset", "--", "whatsapp.reply_prefix"]))
    }

    /// S07-F7: Hermes's default mode is self-chat (`whatsapp_common.py:77`).
    @Test func modeDefaultsToSelfChat() async {
        #expect(WhatsAppSetupViewModel.mode(fromEnv: nil) == "self-chat")
        #expect(WhatsAppSetupViewModel.mode(fromEnv: "  ") == "self-chat")
        #expect(WhatsAppSetupViewModel.mode(fromEnv: "bot") == "bot")
        let vm = await loaded(env: "WHATSAPP_ENABLED=true\n", config: "")
        #expect(vm.mode == "self-chat")
        #expect(vm.savePlan().env["WHATSAPP_MODE"] == "self-chat")
    }
}

// MARK: - S07-F7 Feishu

@Suite("B05 · S07-F7 Feishu domain default")
struct FeishuDomainB05Tests {
    /// `gateway/config_env.py:578`, `feishu/adapter.py:1387` — `feishu`.
    @Test func absentOrBlankIsFeishu() {
        #expect(FeishuSetupViewModel.domain(fromEnv: nil) == "feishu")
        #expect(FeishuSetupViewModel.domain(fromEnv: "") == "feishu")
        #expect(FeishuSetupViewModel.domain(fromEnv: "Lark") == "lark")
    }
}

// MARK: - S07-F5 BlueBubbles

@Suite("B05 · S07-F5 iMessage read receipts")
@MainActor
struct IMessageReadReceiptsB05Tests {
    /// `getenv(env, "true")` + `is_truthy_value` (`config_env.py:619`).
    @Test func absentIsOnAndPresentIsParsed() {
        #expect(IMessageSetupViewModel.sendReadReceipts(fromEnv: nil))
        #expect(IMessageSetupViewModel.sendReadReceipts(fromEnv: "true"))
        #expect(!IMessageSetupViewModel.sendReadReceipts(fromEnv: "false"))
        #expect(!IMessageSetupViewModel.sendReadReceipts(fromEnv: ""))
    }

    /// Round trip: turning it off writes `false` (not an unset, which Hermes
    /// reads as on), and a reload shows it off.
    @Test func offIsWrittenExplicitlyAndReadsBackOff() async {
        let ctx = scratchContext("bb")
        try? "BLUEBUBBLES_SERVER_URL=http://mac:1234\nBLUEBUBBLES_PASSWORD=pw\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let vm = IMessageSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.sendReadReceipts, "absent = Hermes's default, on")
        vm.sendReadReceipts = false
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("BLUEBUBBLES_SEND_READ_RECEIPTS=false"), "\(env)")
        let again = IMessageSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        again.load()
        await until(timeout: 10) { !again.isLoading }
        #expect(again.sendReadReceipts == false)
    }
}

// MARK: - S07-F4 Mattermost

@Suite("B05 · S07-F4 Mattermost require_mention follows the host's precedence")
@MainActor
struct MattermostPrecedenceB05Tests {
    /// v0.21.3+ (`extra_or_secret`): a non-blank env line wins.
    @Test func envWinsFromV0213() {
        let r = MattermostSetupViewModel.resolveRequireMention(envValue: "true", configValue: false, envWins: true)
        #expect(r.value == true)
        #expect(r.fromEnv)
        let blank = MattermostSetupViewModel.resolveRequireMention(envValue: " ", configValue: false, envWins: true)
        #expect(blank.value == false, "a blank env value is unset (`_shared.py:123-125`)")
    }

    /// Up to v0.21.2 config.yaml won; unchanged there.
    @Test func configWinsBeforeV0213() {
        let r = MattermostSetupViewModel.resolveRequireMention(envValue: "true", configValue: false, envWins: false)
        #expect(r.value == false)
        #expect(!r.fromEnv)
        let absent = MattermostSetupViewModel.resolveRequireMention(envValue: "no", configValue: nil, envWins: false)
        #expect(absent.value == false && absent.fromEnv)
        let none = MattermostSetupViewModel.resolveRequireMention(envValue: nil, configValue: nil, envWins: true)
        #expect(none.value == true && !none.fromEnv, "the adapter's own default")
    }

    /// Save writes config.yaml and removes the stale `.env` line, so both
    /// sides of the flip read the value the user chose.
    @Test func saveMovesTheValueToConfigAndDropsTheEnvLine() async {
        let ctx = scratchContext("mm")
        try? "MATTERMOST_URL=https://mm.example\nMATTERMOST_REQUIRE_MENTION=true\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "mattermost:\n  require_mention: false\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { args in args.starts(with: ["config", "set"]) ? ("✓ Set \(args[3])", 0) : ("", 0) }
        let vm = MattermostSetupViewModel(context: ctx, cliRunner: cli.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.requireMentionCaption != nil)
        vm.requireMention = false
        let plan = vm.savePlan()
        #expect(plan.config["mattermost.require_mention"] == "false")
        #expect(plan.env["MATTERMOST_REQUIRE_MENTION"] == "")
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("# MATTERMOST_REQUIRE_MENTION=true"), "\(env)")
        #expect(cli.calls.contains { $0.starts(with: ["config", "set"]) && $0.contains("mattermost.require_mention") })
    }

    /// No env line → nothing to remove.
    @Test func noEnvLineNoUnset() async {
        let ctx = scratchContext("mm2")
        try? "MATTERMOST_URL=https://mm.example\n".write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let vm = MattermostSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.savePlan().env["MATTERMOST_REQUIRE_MENTION"] == nil)
        #expect(vm.requireMentionCaption == nil)
    }
}

// MARK: - S07-F8 Webhooks

@Suite("B05 · S07-F8 a failed webhook list is not an empty board")
struct WebhookListFailureB05Tests {
    @Test func timeoutAndCrashAreFailures() {
        if case .failed = WebhooksViewModel.classify(output: "Command timed out after 30s.", exitCode: -1) {} else {
            Issue.record("timeout read as a listing")
        }
        if case .failed = WebhooksViewModel.classify(output: "", exitCode: -1) {} else {
            Issue.record("no output from a failed run read as a listing")
        }
        if case .failed = WebhooksViewModel.classify(output: "Traceback (most recent call last):\nKeyError: 'x'", exitCode: 1) {} else {
            Issue.record("a crash read as a listing")
        }
    }

    @Test func realAnswersAreKept() {
        #expect(WebhooksViewModel.classify(output: "No dynamic webhook subscriptions.\n", exitCode: 0) == .entries([]))
        #expect(WebhooksViewModel.classify(output: "", exitCode: 0) == .entries([]))
        #expect(WebhooksViewModel.classify(
            output: "Webhook platform is not enabled. Run the gateway setup wizard", exitCode: 0) == .notEnabled)
        let listing = "\n  ◆ github\n    URL: http://localhost:8644/webhooks/github\n    Events: push\n    Deliver: log\n"
        if case .entries(let rows) = WebhooksViewModel.classify(output: listing, exitCode: 0) {
            #expect(rows.map(\.name) == ["github"])
        } else {
            Issue.record("a real listing was not read")
        }
    }
}

// MARK: - S07-F6 Spotify

@Suite("B05 · S07-F6 Spotify client ID and remote guidance")
@MainActor
struct SpotifyB05Tests {
    /// `--client-id` is in the argparse from v2026.4.30 (`main.py:8444`) to
    /// v2026.9.24 (`subcommands/auth.py:76-77`).
    @Test func argvCarriesTheClientIDOnlyWhenGiven() {
        #expect(SpotifyAuthFlow.argv(clientID: nil) == ["auth", "spotify"])
        #expect(SpotifyAuthFlow.argv(clientID: "") == ["auth", "spotify"])
        #expect(SpotifyAuthFlow.argv(clientID: "0123456789abcdef0123456789abcdef")
            == ["auth", "spotify", "--client-id=0123456789abcdef0123456789abcdef"])
    }

    @Test func onlyAPlainIDIsAccepted() {
        #expect(SpotifyAuthFlow.isPlausibleClientID("0123456789abcdef0123456789abcdef"))
        #expect(SpotifyAuthFlow.isPlausibleClientID("  0123456789abcdef0123456789abcdef \n"))
        #expect(!SpotifyAuthFlow.isPlausibleClientID(""))
        #expect(!SpotifyAuthFlow.isPlausibleClientID("--scope x"))
        #expect(!SpotifyAuthFlow.isPlausibleClientID("abc def 0123456789"))
        #expect(!SpotifyAuthFlow.isPlausibleClientID("https://developer.spotify.com"))
    }

    /// `_spotify_setting`'s sources (`auth_spotify.py:36-52`).
    @Test func knownClientIDSources() {
        #expect(SpotifyAuthFlow.hasKnownClientID(env: ["HERMES_SPOTIFY_CLIENT_ID": "abc"], authJSON: nil))
        #expect(SpotifyAuthFlow.hasKnownClientID(env: ["SPOTIFY_CLIENT_ID": "abc"], authJSON: nil))
        #expect(!SpotifyAuthFlow.hasKnownClientID(env: ["HERMES_SPOTIFY_CLIENT_ID": " "], authJSON: nil))
        let auth = Data(#"{"providers":{"spotify":{"client_id":"abc","access_token":"t"}}}"#.utf8)
        #expect(SpotifyAuthFlow.hasKnownClientID(env: [:], authJSON: auth))
        #expect(!SpotifyAuthFlow.hasKnownClientID(env: [:], authJSON: Data(#"{"providers":{}}"#.utf8)))
    }

    /// `_spotify_redirect_uri`'s order (`auth_spotify.py:67-70`).
    @Test func redirectURIFollowsTheHostsSetting() {
        #expect(SpotifyAuthFlow.redirectURI(env: [:], authJSON: nil) == "http://127.0.0.1:43827/spotify/callback")
        #expect(SpotifyAuthFlow.redirectURI(env: ["SPOTIFY_REDIRECT_URI": "http://127.0.0.1:9999/cb"], authJSON: nil)
            == "http://127.0.0.1:9999/cb")
        let auth = Data(#"{"providers":{"spotify":{"redirect_uri":"http://127.0.0.1:5555/cb"}}}"#.utf8)
        #expect(SpotifyAuthFlow.redirectURI(env: [:], authJSON: auth) == "http://127.0.0.1:5555/cb")
        #expect(SpotifyAuthFlow.redirectURI(env: ["HERMES_SPOTIFY_REDIRECT_URI": "http://127.0.0.1:7777/cb"], authJSON: auth)
            == "http://127.0.0.1:7777/cb")
        #expect(SpotifyAuthFlow.callbackPort(of: "http://127.0.0.1:7777/cb") == 7777)
    }

    /// A remote window gets ssh with the callback port forwarded, then
    /// `hermes auth spotify` on the host.
    @Test func remoteCommandForwardsTheCallbackPort() {
        let ctx = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box.example", user: "alan")))
        let line = SpotifyAuthFlow.remoteCommandLine(for: ctx)
        #expect(line.contains("'-L' '43827:127.0.0.1:43827'"), "\(line)")
        #expect(line.contains("'alan@box.example'"))
        #expect(line.contains("'auth' 'spotify' '--no-browser'"), "\(line)")
        #expect(line.hasPrefix("'/usr/bin/ssh' '-t'"))
        #expect(SpotifyAuthFlow.remoteCommandLine(for: ctx, redirectURI: "http://127.0.0.1:9999/cb")
            .contains("'-L' '9999:127.0.0.1:9999'"))
    }

    /// The gateway-setup command it shares a builder with is unchanged.
    @Test func gatewaySetupLineIsUnchanged() {
        let ctx = ServerContext(
            id: UUID(), displayName: "box",
            kind: .ssh(SSHConfig(host: "box.example", user: "alan")))
        #expect(GatewaySetupTerminalCommand.shellLine(for: ctx)
            == GatewaySetupTerminalCommand.shellLine(for: ctx, hermesArgs: ["gateway", "setup"]))
        #expect(!GatewaySetupTerminalCommand.shellLine(for: ctx).contains("'-L'"))
    }
}

// MARK: - S07-F3 restart drain

@Suite("B05 · S07-F3 a restart held for the current turn is followed, not failed")
@MainActor
struct GatewayRestartDrainWatchB05Tests {

    nonisolated static func record(pid: Int, state: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["pid": pid, "gateway_state": state])
    }

    final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Data?]
        init(_ q: [Data?]) { queue = q }
        func next() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
        }
    }

    @Test func theWatchEndsWhenAReplacementIsRunning() async {
        let states = States([Self.record(pid: 100, state: "draining"),
                             Self.record(pid: 100, state: "stopped"),
                             Self.record(pid: 200, state: "starting"),
                             Self.record(pid: 200, state: "running")])
        let watcher = GatewayRestartDrainWatcher(readState: { states.next() }, interval: .milliseconds(20))
        var finished = 0
        watcher.onFinished = { finished += 1 }
        watcher.start(from: .init(pid: 100, state: "draining", activeWork: ["chat turn, running 5s"]), budgetSeconds: 60)
        #expect(watcher.pendingWork == ["chat turn, running 5s"])
        await until(timeout: 5) { watcher.status == .restarted }
        #expect(watcher.status == .restarted)
        #expect(finished == 1)
    }

    @Test func leavingStopsTheWatchOnly() async {
        let watcher = GatewayRestartDrainWatcher(
            readState: { Self.record(pid: 100, state: "draining") }, interval: .milliseconds(20))
        watcher.start(from: .init(pid: 100, state: "draining"), budgetSeconds: 60)
        #expect(watcher.isWatching)
        var finished = 0
        watcher.onFinished = { finished += 1 }
        watcher.stopWatching()
        #expect(watcher.status == .left)
        #expect(finished == 1, "the pane settles its note on Stop Waiting too")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(watcher.status == .left, "a cancelled poll must not overwrite the user's choice")
    }

    @Test func itGivesUpAfterHermesOwnBudget() async {
        let watcher = GatewayRestartDrainWatcher(
            readState: { Self.record(pid: 100, state: "draining") },
            interval: .milliseconds(20), graceSeconds: 0)
        watcher.start(from: .init(pid: 100, state: "draining"), budgetSeconds: 0)
        await until(timeout: 5) { watcher.status == .gaveUp }
        #expect(watcher.status == .gaveUp)
    }

    /// The old gateway exited and nothing brought a new one: say so after the
    /// revival grace instead of waiting out Hermes's whole budget.
    @Test func aGatewayNobodyRevivesIsReported() async {
        let states = States([Self.record(pid: 100, state: "stopped")])
        let watcher = GatewayRestartDrainWatcher(
            readState: { states.next() }, interval: .milliseconds(20), revivalGraceSeconds: 0)
        var finished = 0
        watcher.onFinished = { finished += 1 }
        watcher.start(from: .init(pid: 100, state: "draining", restartRequested: true), budgetSeconds: 600)
        await until(timeout: 5) { watcher.status == .notRevived }
        #expect(watcher.status == .notRevived)
        #expect(finished == 1)
    }

    @Test func aFailedReplacementIsReported() async {
        let states = States([Self.record(pid: 100, state: "draining"),
                             try! JSONSerialization.data(withJSONObject: [
                                "pid": 300, "gateway_state": "startup_failed", "exit_reason": "no platforms"])])
        let watcher = GatewayRestartDrainWatcher(readState: { states.next() }, interval: .milliseconds(20))
        watcher.start(from: .init(pid: 100, state: "draining"), budgetSeconds: 60)
        await until(timeout: 5) { if case .failed = watcher.status { return true }; return false }
        #expect(watcher.status == .failed("no platforms"))
    }

    /// End to end through the Gateway pane: a launchd restart that hits the
    /// 60 s cap while `gateway_state.json` says draining starts the watch
    /// instead of painting "Gateway restart failed".
    @Test func theGatewayPaneWatchesInsteadOfFailing() async {
        let ctx = scratchContext("gw")
        try? #"{"pid": 812, "gateway_state": "draining", "restart_requested": true, "active_work": [{"kind": "chat", "elapsed_s": 42}]}"#
            .write(toFile: ctx.paths.gatewayStateJSON, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { args in
            switch args {
            case ["gateway", "status"]:
                return ("Launchd plist: /Users/a/Library/LaunchAgents/ai.hermes.gateway.plist\n✓ Gateway is supervised by launchd (PID 812)\n", 0)
            case ["gateway", "restart"]:
                return ("Command timed out after 60s.", -1)
            default:
                return ("", 0)
            }
        }
        let watcher = GatewayRestartDrainWatcher(
            readState: { try? Data(contentsOf: URL(fileURLWithPath: ctx.paths.gatewayStateJSON)) },
            interval: .seconds(60))
        let vm = MessagingGatewayViewModel(context: ctx, cliRunner: cli.runner, drainWatcher: watcher)
        vm.restartGateway()
        await until(timeout: 10) { !vm.isBusy }
        #expect(cli.calls.contains(["gateway", "restart"]), "premise: the restart was sent: \(cli.calls)")
        #expect(vm.actionFailed == false, "\(vm.actionMessage ?? "")")
        #expect(watcher.isWatching)
        #expect(watcher.pendingWork.count == 1)
        watcher.reset()
    }

    /// Without the drain evidence the same timeout is still a failure — and
    /// a drain that is NOT for a restart (a SIGTERM stop, as the
    /// pre-v2026.8.31 launchd restart sent) is not evidence.
    @Test(arguments: [#"{"pid": 812, "gateway_state": "running"}"#,
                      #"{"pid": 812, "gateway_state": "draining", "restart_requested": false}"#])
    func withoutDrainEvidenceTheTimeoutStillFails(state: String) async {
        let ctx = scratchContext("gw2")
        try? state
            .write(toFile: ctx.paths.gatewayStateJSON, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { args in
            switch args {
            case ["gateway", "status"]:
                return ("✓ Gateway is supervised by launchd (PID 812)\n", 0)
            case ["gateway", "restart"]:
                return ("Command timed out after 60s.", -1)
            default:
                return ("", 0)
            }
        }
        let vm = MessagingGatewayViewModel(context: ctx, cliRunner: cli.runner)
        vm.restartGateway()
        await until(timeout: 10) { !vm.isBusy }
        #expect(vm.actionFailed)
        #expect(!vm.drainWatcher.isWatching)
    }
}
