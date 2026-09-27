import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R08 (Hermes v0.21.5 audit, server transport), the app-target half:
/// the chat credential hint (S15-F4), the Test Connection probe script
/// (S15-F3) and the remote `/scarf-*` bootstrap guard (S03-F5). The
/// transport command lines are covered in ScarfCore's
/// `RemoteHermesResolutionR08Tests`.
@Suite struct ServerTransportR08Tests {

    // MARK: - S15-F4: credential hint

    /// A home with the given `.env` / `config.yaml`, checked with an empty
    /// process environment so the developer's own shell keys can't leak in.
    private static func hasCredential(env: String? = nil, config: String? = nil) throws -> Bool {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        if let env { try env.write(toFile: home.context.paths.envFile, atomically: true, encoding: .utf8) }
        if let config { try config.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8) }
        return HermesFileService(context: home.context).hasAnyAICredential(environment: [:])
    }

    @Test func emptyHomeHasNoCredential() throws {
        #expect(try Self.hasCredential() == false)
        #expect(try Self.hasCredential(env: "# nothing yet\nGROQ_API_KEY=gsk\n") == false)
        #expect(try Self.hasCredential(config: "model:\n  default: claude-sonnet-4\n  provider: anthropic\n") == false)
    }

    /// The audit's case: `hermes setup` wrote a DeepSeek key, which the old
    /// 11-key list didn't know, so chat showed the banner while working.
    @Test func aProviderKeyScarfNeverListedCounts() throws {
        #expect(try Self.hasCredential(env: "DEEPSEEK_API_KEY=sk-live\n"))
        #expect(try Self.hasCredential(env: "export ZAI_API_KEY='k'\n"))
        #expect(try Self.hasCredential(env: "MINIMAX_API_KEY=mm-real\n"))
    }

    @Test func aKeylessLocalEndpointCounts() throws {
        #expect(try Self.hasCredential(config: """
            model:
              default: llama3.1
              provider: custom
              base_url: http://localhost:11434/v1
            """))
        #expect(try Self.hasCredential(config: "model:\n  default: qwen\n  provider: lmstudio\n"))
        #expect(try Self.hasCredential(env: "OPENAI_BASE_URL=http://127.0.0.1:8000/v1\n"))
    }

    /// Hermes' setup writes a public `model.base_url` for keyed providers;
    /// that alone must not hide a missing key.
    @Test func aPublicBaseURLWithoutAKeyIsStillMissing() throws {
        #expect(try Self.hasCredential(config: """
            model:
              default: anthropic/claude-sonnet-4
              provider: openrouter
              base_url: https://openrouter.ai/api/v1
            """) == false)
    }

    /// A GITHUB_TOKEN kept in `.env` for the GitHub tools is not a model
    /// credential unless the model provider is Copilot.
    @Test func aGitHubTokenCountsOnlyForCopilot() throws {
        let anthropic = "model:\n  default: claude-sonnet-4\n  provider: anthropic\n"
        let copilot = "model:\n  default: gpt-5\n  provider: copilot\n"
        #expect(try Self.hasCredential(env: "GITHUB_TOKEN=ghp_real\n", config: anthropic) == false)
        #expect(try Self.hasCredential(env: "GITHUB_TOKEN=ghp_real\n", config: copilot))
        // R16c F3: Hermes' aliases for Copilot / Hugging Face count too.
        let github = "model:\n  default: gpt-5\n  provider: github\n"
        let hf = "model:\n  default: m\n  provider: hf\n"
        #expect(try Self.hasCredential(env: "GITHUB_TOKEN=ghp_real\n", config: github))
        #expect(try Self.hasCredential(env: "HF_TOKEN=hf_real\n", config: hf))
        #expect(try Self.hasCredential(env: "HF_TOKEN=hf_real\n", config: github) == false)
    }

    // MARK: - R16c F2: what Add Server saves

    /// A path the probe found is saved marked as a path (one word, spaces
    /// and all); a typed value — or a probe that only echoed a typed value
    /// back — is not.
    @MainActor @Test func aProbedPathIsSavedAsAPath() {
        let vm = AddServerViewModel()
        vm.host = "box"
        vm.testResult = .success(hermesPath: "/Users/Jane Doe/.local/bin/hermes", dbFound: true, suggestedRemoteHome: nil)
        let probed = vm.configForSave()
        #expect(probed.hermesBinaryHint == "/Users/Jane Doe/.local/bin/hermes")
        #expect(probed.hermesBinaryHintIsPath == true)
        #expect(probed.hermesBinaryHintFragment == nil)

        vm.hermesBinary = "docker compose exec hermes hermes"
        let typed = vm.configForSave()
        #expect(typed.hermesBinaryHint == "docker compose exec hermes hermes")
        #expect(typed.hermesBinaryHintIsPath == nil)
        #expect(typed.hermesBinaryHintFragment == "docker compose exec hermes hermes")

        // Tested WITH the wrapper, then the field cleared: the "path" in the
        // result is the wrapper echoed back, so it keeps the typed reading.
        vm.hermesBinary = ""
        vm.testedWithTypedBinary = true
        vm.testResult = .success(hermesPath: "docker compose exec hermes hermes", dbFound: true, suggestedRemoteHome: nil)
        #expect(vm.configForSave().hermesBinaryHintIsPath == nil)
    }

    @Test func theProcessEnvironmentUsesTheSameTable() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let svc = HermesFileService(context: home.context)
        #expect(svc.hasAnyAICredential(environment: ["KIMI_API_KEY": "k"]))
        #expect(!svc.hasAnyAICredential(environment: ["KIMI_API_KEY": ""]))
        #expect(!svc.hasAnyAICredential(environment: nil))
    }

    // MARK: - S15-F3: Test Connection probe

    /// Runs the probe script the way the fixed probe does — on `/bin/sh -s`
    /// stdin — in a throwaway `$HOME`, and returns its `HERMES:` line.
    private static func probeHermesLine(
        hint: String?, home: URL, sh: String = "/bin/sh", loginShell: String = "/bin/sh"
    ) throws -> String {
        let script = TestConnectionProbe.probeScript(config: SSHConfig(host: "box", hermesBinaryHint: hint))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sh)
        proc.arguments = ["-s"]
        proc.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": loginShell]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        return out.split(separator: "\n").first { $0.hasPrefix("HERMES:") }.map(String.init) ?? ""
    }

    private static func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scarf-r08-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A wrapper hint is reported as typed, not as its first word's path
    /// (`/bin/sh` here, `/usr/bin/docker` in the field).
    @Test func aWrapperHintSurvivesTheProbe() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try Self.probeHermesLine(hint: "sh -c 'exec hermes \"$@\"' hermes", home: home)
            == "HERMES:sh -c 'exec hermes \"$@\"' hermes")
    }

    /// A single-word hint still resolves through `command -v`.
    @Test func aSingleWordHintResolvesToItsPath() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try Self.probeHermesLine(hint: "sh", home: home) == "HERMES:/bin/sh")
    }

    /// No hint: the probe falls back to the install candidates, so a
    /// `~/.local/bin/hermes` that a non-login PATH can't see is found.
    @Test func noHintFindsTheLocalBinInstall() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hermes = bin.appendingPathComponent("hermes")
        try "#!/bin/sh\n".write(to: hermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hermes.path)
        #expect(try Self.probeHermesLine(hint: nil, home: home) == "HERMES:\(hermes.path)")
    }

    /// Ubuntu's `/bin/sh` is dash, and a `.zshrc` full of zsh syntax used
    /// to be sourced into it, which ended the probe with no `HERMES:` line.
    /// The probe now borrows the login shell's PATH instead: a `hermes`
    /// that `.profile` puts on PATH is found, and the `.zshrc` is never read.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/dash")))
    func underDashTheLoginPathIsUsedAndZshSyntaxIsHarmless() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("opt/tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hermes = bin.appendingPathComponent("hermes")
        try "#!/bin/sh\n".write(to: hermes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hermes.path)
        try "plugins=(git)\nprint -l ${(f)x}\nread answer\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "echo welcome\nexport PATH=\"$HOME/opt/tools:$PATH\"\n"
            .write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        #expect(try Self.probeHermesLine(hint: nil, home: home, sh: "/bin/dash", loginShell: "/bin/bash")
            == "HERMES:\(hermes.path)")
    }

    // MARK: - S03-F5: remote slash-command bootstrap

    /// The window hook is for remote hosts only; the local home is handled
    /// at launch. A local context must not be written to from here.
    @Test func theWindowBootstrapSkipsLocalContexts() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        await SlashCommandBootstrapService.bootstrapRemoteIfNeeded(context: home.context)
        #expect(!FileManager.default.fileExists(atPath: home.context.paths.globalSlashCommandsDir))
    }

    // The positive paths (R16c). A REMOTE-shaped context whose Hermes home is
    // a local temp dir, driven through `LocalTransport` — the same file
    // operations SSH would run, minus the network — and a fixture bundle of
    // two commands. Each test uses a fresh server id, so the once-per-session
    // set is never shared between them.

    private struct RemoteFixture {
        let home: URL
        let bundle: URL
        let context: ServerContext
        var commandsDir: String { context.paths.globalSlashCommandsDir }

        init(withHermesHome: Bool = true) throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("scarf-r16c-slash-\(UUID().uuidString)")
            home = base.appendingPathComponent("hermes")
            bundle = base.appendingPathComponent("BuiltinSlashCommands.bundle")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            if withHermesHome {
                try "model:\n  default: x\n".write(
                    to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
            }
            for name in ["scarf-help", "scarf-cron"] {
                try "---\nname: \(name)\nversion: 1.2.0\n---\nBody of \(name).\n".write(
                    to: bundle.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
            }
            context = ServerContext(id: UUID(), displayName: "Box", kind: .ssh(SSHConfig(
                host: "box.invalid", remoteHome: home.path)))
        }

        func bootstrap() async -> Bool {
            let id = context.id
            return await SlashCommandBootstrapService.bootstrapRemoteIfNeeded(
                context: context,
                makeTransport: { _ in LocalTransport(contextID: id) },
                bundleCommandsDir: bundle)
        }

        func cleanup() { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    }

    @Test func aRemoteHostGetsTheBundledCommands() async throws {
        let fx = try RemoteFixture()
        defer { fx.cleanup() }
        #expect(await fx.bootstrap())
        let installed = try FileManager.default.contentsOfDirectory(atPath: fx.commandsDir).sorted()
        #expect(installed == ["scarf-cron.md", "scarf-help.md"])
        let text = try String(contentsOfFile: fx.commandsDir + "/scarf-help.md", encoding: .utf8)
        #expect(text.contains("version: 1.2.0"))
    }

    /// Once per host per app session: a second window on the same host runs
    /// nothing, so a command deleted after the first run stays deleted.
    @Test func aHostIsBootstrappedOncePerSession() async throws {
        let fx = try RemoteFixture()
        defer { fx.cleanup() }
        #expect(await fx.bootstrap())
        try FileManager.default.removeItem(atPath: fx.commandsDir + "/scarf-help.md")
        #expect(await fx.bootstrap() == false)
        #expect(!FileManager.default.fileExists(atPath: fx.commandsDir + "/scarf-help.md"))
    }

    /// A failed run is forgotten, so the next window on the host retries.
    /// The failure here is a real one: `scarf` is a FILE, so the commands
    /// directory can't be created.
    @Test func aFailedRunIsRetriedByTheNextWindow() async throws {
        let fx = try RemoteFixture()
        defer { fx.cleanup() }
        let blocker = fx.home.appendingPathComponent("scarf")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        #expect(await fx.bootstrap() == false)
        try FileManager.default.removeItem(at: blocker)
        #expect(await fx.bootstrap())
        #expect(FileManager.default.fileExists(atPath: fx.commandsDir + "/scarf-cron.md"))
    }

    /// No `config.yaml` and no `state.db`: a wrong `remoteHome` or a deleted
    /// profile. Nothing is created (a stray `profiles/<name>/` would show up
    /// as a profile on older Hermes), and the host is retried later, when the
    /// home may exist.
    @Test func aMissingHermesHomeIsSkippedAndRetried() async throws {
        let fx = try RemoteFixture(withHermesHome: false)
        defer { fx.cleanup() }
        #expect(await fx.bootstrap() == false)
        #expect(!FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("scarf").path))
        try "".write(to: fx.home.appendingPathComponent("state.db"), atomically: true, encoding: .utf8)
        #expect(await fx.bootstrap())
    }
}
