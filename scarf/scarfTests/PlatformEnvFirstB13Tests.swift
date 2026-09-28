import Testing
import Foundation
@testable import scarf
import ScarfCore

// B13 — env-first platform settings (Discord + Telegram). Hermes citations
// @ v2026.9.24 unless stated; see `PlatformEnvSetting`.

private func scratchContext(_ tag: String) -> ServerContext {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scarf-b13-\(tag)-\(UUID().uuidString)")
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

/// The v0.21.5 reference checkout the round-trip tests run Hermes from.
private let hermesRefAvailable = FileManager.default.isExecutableFile(
    atPath: NSHomeDirectory() + "/.hermes/hermes-agent-v0215/.venv/bin/python")

private let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
private let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")

@MainActor
struct DiscordEnvFirstB13Tests {
    /// The form shows what the gateway uses and a Save moves the `.env`
    /// lines into config.yaml, removing them only after `config set` works.
    @Test func envOverridesShowAndSaveMovesThem() async {
        let ctx = scratchContext("dc")
        try? "DISCORD_BOT_TOKEN=t\nDISCORD_REQUIRE_MENTION=false\nDISCORD_REACTIONS=no\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "discord:\n  require_mention: true\n  reactions: true\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { args in args.starts(with: ["config", "set"]) ? ("✓ Set \(args[3])", 0) : ("", 0) }
        let vm = DiscordSetupViewModel(context: ctx, cliRunner: cli.runner)
        vm.load(capabilities: v0215)
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.requireMention == false)
        #expect(vm.reactions == false)
        #expect(vm.autoThread == true)
        #expect(vm.envCaption(for: "DISCORD_REQUIRE_MENTION") != nil)
        #expect(vm.envCaption(for: "DISCORD_AUTO_THREAD") == nil)
        let plan = vm.savePlan()
        #expect(plan.config["discord.require_mention"] == "false")
        #expect(plan.config["discord.reactions"] == "false")
        #expect(Set(plan.envUnsetAfterConfig) == ["DISCORD_REQUIRE_MENTION", "DISCORD_REACTIONS"])
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("# DISCORD_REQUIRE_MENTION=false"), "\(env)")
        #expect(env.contains("# DISCORD_REACTIONS=no"), "\(env)")
        #expect(env.contains("DISCORD_BOT_TOKEN=t"))
    }

    /// A failed `config set` keeps the `.env` lines — the only copy Hermes reads.
    @Test func failedConfigSetKeepsEnvLines() async {
        let ctx = scratchContext("dcfail")
        try? "DISCORD_BOT_TOKEN=t\nDISCORD_REQUIRE_MENTION=false\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { _ in ("Error: nope", 1) }
        let vm = DiscordSetupViewModel(context: ctx, cliRunner: cli.runner)
        vm.load(capabilities: v0215)
        await until(timeout: 10) { !vm.isLoading }
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        #expect(vm.messageIsFailure)
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("\nDISCORD_REQUIRE_MENTION=false"), "\(env)")
    }

    /// Pre-v0.21.3: config.yaml wins for require_mention; the line is
    /// unused and the caption says so. history_backfill on a pre-v0.14
    /// host is neither written nor its line removed.
    @Test func olderHostShowsConfigAndKeepsHiddenRowLine() async {
        let ctx = scratchContext("dcold")
        try? "DISCORD_REQUIRE_MENTION=false\nDISCORD_HISTORY_BACKFILL=false\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "discord:\n  require_mention: true\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = DiscordSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        let v013 = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        vm.load(capabilities: v013)
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.requireMention == true)
        #expect(vm.envCaption(for: "DISCORD_REQUIRE_MENTION")?.contains("unused") == true)
        let plan = vm.savePlan()
        #expect(plan.config["discord.history_backfill"] == nil)
        #expect(plan.envUnsetAfterConfig == ["DISCORD_REQUIRE_MENTION"])
    }
}

@MainActor
struct TelegramEnvFirstB13Tests {
    @Test func envOverridesShowAndMove() async {
        let ctx = scratchContext("tg")
        try? "TELEGRAM_BOT_TOKEN=t\nTELEGRAM_REACTIONS=true\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "telegram:\n  reactions: false\n  require_mention: true\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = TelegramSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        vm.load(capabilities: v0212)
        await until(timeout: 10) { !vm.isLoading }
        // reactions: env-only reader before v0.21.3 too.
        #expect(vm.reactions == true)
        #expect(vm.requireMention == true)
        #expect(vm.savePlan().envUnsetAfterConfig == ["TELEGRAM_REACTIONS"])
    }

    /// Absent config key: `.env` decides on every version.
    @Test func absentConfigKeyFallsBackToEnv() async {
        let ctx = scratchContext("tg2")
        try? "TELEGRAM_REQUIRE_MENTION=yes\n".write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let vm = TelegramSetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        vm.load(capabilities: v0212)
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.requireMention == true)
        #expect(vm.envCaption(for: "TELEGRAM_REQUIRE_MENTION")?.contains("sets this now") == true)
    }
}

@MainActor
struct AllowlistEnvFirstB13Tests {
    /// Never drop the only allowlist: emptying the list while `.env`
    /// still holds entries refuses rather than opening the platform.
    @Test func emptyListWithEnvEntriesRefuses() {
        let line = GatewayBehaviorViewModel.EnvAllowlistLine(key: "DISCORD_ALLOWED_CHANNELS", entries: ["1"], decides: true)
        let plan = GatewayBehaviorViewModel.envLinePlan(line, savingItems: [])
        #expect(plan.refusal != nil && plan.unsetAfter == nil)
        let ok = GatewayBehaviorViewModel.envLinePlan(line, savingItems: ["1"])
        #expect(ok.refusal == nil && ok.unsetAfter == "DISCORD_ALLOWED_CHANNELS")
        let blank = GatewayBehaviorViewModel.EnvAllowlistLine(key: "TELEGRAM_ALLOWED_CHATS", entries: [], decides: false)
        #expect(GatewayBehaviorViewModel.envLinePlan(blank, savingItems: []).unsetAfter == "TELEGRAM_ALLOWED_CHATS")
        #expect(GatewayBehaviorViewModel.envLinePlan(nil, savingItems: []) == (nil, nil))
    }

    /// Load shows the list the gateway uses — the `.env` one on Discord.
    @Test func loadShowsEnvAllowlist() async {
        let ctx = scratchContext("al")
        try? "DISCORD_ALLOWED_CHANNELS=111, 222\n".write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "discord:\n  allowed_channels:\n  - \"999\"\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = GatewayBehaviorViewModel(platform: "discord", capabilities: v0212, context: ctx)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.items == ["111", "222"])
        #expect(vm.allowlistEnvCaption?.contains("sets this now") == true)
    }

    /// Scarf writes the list and drops the `.env` line; Hermes's own loader
    /// then reads the list from config.yaml. Runs Hermes from the v0.21.5
    /// reference checkout's venv when present.
    @Test(.enabled(if: hermesRefAvailable, "needs ~/.hermes/hermes-agent-v0215")) func roundTripThroughHermesLoader() async throws {
        let ctx = scratchContext("rt")
        try "DISCORD_BOT_TOKEN=t\nDISCORD_ALLOWED_CHANNELS=111,222\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try "discord:\n  require_mention: true\n".write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        #expect(GatewayConfigWriter.saveList(context: ctx, platform: "discord", key: "allowed_channels", items: ["111", "222"]))
        let outcome = PlatformSetupHelpers.saveForm(
            context: ctx, envPairs: [:], configKV: [:], envUnsetAfterConfig: ["DISCORD_ALLOWED_CHANNELS"])
        #expect(!outcome.isFailure)
        let env = try String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)
        #expect(env.contains("# DISCORD_ALLOWED_CHANNELS=111,222"))

        let py = NSHomeDirectory() + "/.hermes/hermes-agent-v0215/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: py) else { return }
        let script = """
        import os, sys, json, pathlib
        home = sys.argv[1]
        for k in list(os.environ):
            if k.startswith(("DISCORD_", "TELEGRAM_")): del os.environ[k]
        os.environ["HERMES_HOME"] = home
        from hermes_cli.env_loader import load_hermes_dotenv
        load_hermes_dotenv(hermes_home=pathlib.Path(home))
        from gateway.config import load_gateway_config, Platform
        from plugins.platforms.discord.adapter import DiscordAdapter
        class D: pass
        d = D(); d.config = load_gateway_config().platforms[Platform.DISCORD]
        D._gate_env = DiscordAdapter._gate_env; D._gate_raw = DiscordAdapter._gate_raw
        D._gate_csv_set = DiscordAdapter.__dict__["_gate_csv_set"]
        print(json.dumps(sorted(DiscordAdapter._get_allowed_channels(d))))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.hermes/hermes-agent-v0215")
        p.arguments = ["-c", script, ctx.paths.home]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.split(separator: "\n").last == "[\"111\", \"222\"]", "\(text)")
    }
}

// MARK: - B13b: Matrix, Ntfy, Slack + Mattermost allowlists

/// Runs a Python snippet under the v0.21.5 reference venv with the scratch
/// home as argv[1]; nil when the checkout is absent.
private func runHermes(_ script: String, home: String) throws -> String? {
    let root = NSHomeDirectory() + "/.hermes/hermes-agent-v0215"
    let py = root + "/.venv/bin/python"
    guard FileManager.default.isExecutableFile(atPath: py) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: py)
    p.currentDirectoryURL = URL(fileURLWithPath: root)
    p.arguments = ["-c", script, home]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").last.map(String.init)
}

@MainActor
struct MatrixNtfyEnvFirstB13bTests {
    @Test func matrixShowsAndMovesEnvOverrides() async {
        let ctx = scratchContext("mx")
        try? "MATRIX_HOMESERVER=https://m.x\nMATRIX_REQUIRE_MENTION=false\nMATRIX_AUTO_THREAD=false\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "matrix:\n  require_mention: true\n  auto_thread: true\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let cli = ScriptedCLI { args in args.starts(with: ["config", "set"]) ? ("✓ Set \(args[3])", 0) : ("", 0) }
        let vm = MatrixSetupViewModel(context: ctx, cliRunner: cli.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        // Capabilities come from the host probe; either band, auto_thread
        // (env-only before v0.21.3) is the `.env` value.
        #expect(vm.autoThread == false)
        #expect(vm.envCaption(for: "MATRIX_AUTO_THREAD")?.contains("sets this now") == true)
        #expect(vm.envCaption(for: "MATRIX_DM_MENTION_THREADS") == nil)
        #expect(Set(vm.savePlan().envUnsetAfterConfig) == ["MATRIX_REQUIRE_MENTION", "MATRIX_AUTO_THREAD"])
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("# MATRIX_AUTO_THREAD=false"), "\(env)")
        #expect(env.contains("MATRIX_HOMESERVER=https://m.x"))
    }

    @Test func ntfyPublishTopicFromEnvMoves() async {
        let ctx = scratchContext("nt")
        try? "NTFY_TOPIC=t\nNTFY_PUBLISH_TOPIC=envtopic\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let vm = NtfySetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("", 0) }.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        // Config key absent: `.env` decides on every band.
        #expect(vm.publishTopic == "envtopic")
        #expect(vm.publishTopicCaption?.contains("sets this now") == true)
        let plan = vm.savePlan()
        #expect(plan.config["platforms.ntfy.extra.publish_topic"] == "envtopic")
        #expect(plan.envUnsetAfterConfig == ["NTFY_PUBLISH_TOPIC"])
    }

    @Test func ntfyFailedConfigSetKeepsEnvLine() async {
        let ctx = scratchContext("ntf")
        try? "NTFY_TOPIC=t\nNTFY_PUBLISH_TOPIC=envtopic\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let vm = NtfySetupViewModel(context: ctx, cliRunner: ScriptedCLI { _ in ("Error: nope", 1) }.runner)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        vm.save()
        await until(timeout: 10) { !vm.isSaving }
        #expect(vm.messageIsFailure)
        let env = (try? String(contentsOfFile: ctx.paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("\nNTFY_PUBLISH_TOPIC=envtopic"), "\(env)")
    }
}

@MainActor
struct AllowlistEnvFirstB13bTests {
    @Test(arguments: [("matrix", "MATRIX_ALLOWED_ROOMS", "!a:x,!b:x", ["!a:x", "!b:x"]),
                      ("slack", "SLACK_ALLOWED_CHANNELS", "C1", ["C1"]),
                      ("mattermost", "MATTERMOST_ALLOWED_CHANNELS", "m1,m2", ["m1", "m2"])])
    func loadShowsEnvListWhenConfigHasNone(platform: String, key: String, raw: String, expected: [String]) async {
        let ctx = scratchContext("al-\(platform)")
        try? "\(key)=\(raw)\n".write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        let vm = GatewayBehaviorViewModel(platform: platform, capabilities: v0212, context: ctx)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.items == expected)
        #expect(vm.allowlistEnvCaption?.contains("sets this now") == true)
        #expect(GatewayBehaviorViewModel.envLinePlan(vm.envLine, savingItems: []).refusal != nil)
    }

    /// Before v0.21.3 config wins for these lists: the form shows config's.
    @Test func olderHostShowsConfigList() async {
        let ctx = scratchContext("al-old")
        try? "SLACK_ALLOWED_CHANNELS=C1\n".write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        try? "slack:\n  allowed_channels:\n  - \"C9\"\n".write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        let vm = GatewayBehaviorViewModel(platform: "slack", capabilities: v0212, context: ctx)
        vm.load()
        await until(timeout: 10) { !vm.isLoading }
        #expect(vm.items == ["C9"])
        #expect(vm.allowlistEnvCaption?.contains("unused") == true)
    }

    /// Scarf writes each list + publish_topic stays in config and drops the
    /// `.env` lines; Hermes's own loader then reads the config values.
    @Test(.enabled(if: hermesRefAvailable, "needs ~/.hermes/hermes-agent-v0215")) func roundTripThroughHermesLoader() async throws {
        let ctx = scratchContext("rt2")
        try "MATRIX_ALLOWED_ROOMS=!a:x\nSLACK_ALLOWED_CHANNELS=C1\nMATTERMOST_ALLOWED_CHANNELS=m1\nNTFY_PUBLISH_TOPIC=old\nMATRIX_AUTO_THREAD=true\n"
            .write(toFile: ctx.paths.envFile, atomically: true, encoding: .utf8)
        // What `hermes config set` leaves for the scalars (Hermes's own write).
        try "matrix:\n  auto_thread: false\nplatforms:\n  ntfy:\n    extra:\n      topic: t\n      publish_topic: new\n"
            .write(toFile: ctx.paths.configYAML, atomically: true, encoding: .utf8)
        for (p, k, items) in [("matrix", "allowed_rooms", ["!a:x", "!b:x"]), ("slack", "allowed_channels", ["C1", "C2"]),
                              ("mattermost", "allowed_channels", ["m1", "m2"])] {
            #expect(GatewayConfigWriter.saveList(context: ctx, platform: p, key: k, items: items))
        }
        let outcome = PlatformSetupHelpers.saveForm(
            context: ctx, envPairs: [:], configKV: [:],
            envUnsetAfterConfig: ["MATRIX_ALLOWED_ROOMS", "SLACK_ALLOWED_CHANNELS", "MATTERMOST_ALLOWED_CHANNELS",
                                  "NTFY_PUBLISH_TOPIC", "MATRIX_AUTO_THREAD"])
        #expect(!outcome.isFailure)
        let script = """
        import os, sys, json, pathlib
        home = sys.argv[1]
        for k in list(os.environ):
            if k.startswith(("MATRIX_", "SLACK_", "MATTERMOST_", "NTFY_")): del os.environ[k]
        os.environ["HERMES_HOME"] = home
        from hermes_cli.env_loader import load_hermes_dotenv
        load_hermes_dotenv(hermes_home=pathlib.Path(home))
        from gateway.config import load_gateway_config
        cfg = load_gateway_config()
        def pc(name):
            for p, c in cfg.platforms.items():
                if getattr(p, "value", p) == name: return c
            return type("C", (), {"extra": {}})()
        from plugins.platforms.matrix.adapter import MatrixAdapter, _extra_csv_set
        from plugins.platforms.slack.adapter import SlackAdapter
        from plugins.platforms.mattermost import adapter as mm
        from gateway.platforms._shared import extra_or_secret
        class S: pass
        so = S(); so.config = pc("slack")
        print(json.dumps({
          "rooms": sorted(_extra_csv_set(pc("matrix"), "allowed_rooms", "MATRIX_ALLOWED_ROOMS")),
          "auto_thread": MatrixAdapter._extra_truthy(pc("matrix"), "auto_thread", "MATRIX_AUTO_THREAD", "true"),
          "slack": sorted(SlackAdapter._extra_or_env_channel_set(so, "allowed_channels", "SLACK_ALLOWED_CHANNELS")),
          "mm": sorted(mm._channel_id_set(extra_or_secret(pc("mattermost").extra, "allowed_channels", "MATTERMOST_ALLOWED_CHANNELS", blank_is_unset=False))),
          "ntfy": extra_or_secret(pc("ntfy").extra or {}, "publish_topic", "NTFY_PUBLISH_TOPIC"),
        }, sort_keys=True))
        """
        guard let line = try runHermes(script, home: ctx.paths.home) else { return }
        #expect(line == #"{"auto_thread": false, "mm": ["m1", "m2"], "ntfy": "new", "rooms": ["!a:x", "!b:x"], "slack": ["C1", "C2"]}"#, "\(line)")
    }
}
