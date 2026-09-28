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
    @Test func roundTripThroughHermesLoader() async throws {
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
