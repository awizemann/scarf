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
}
