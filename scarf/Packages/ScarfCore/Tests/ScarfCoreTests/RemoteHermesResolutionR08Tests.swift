import Testing
import Foundation
@testable import ScarfCore

/// R08 (Hermes v0.21.5 audit): how a remote `hermes` is found and invoked.
///
/// - S15-F1: a server saved without Test Connection has no binary hint, and a
///   non-login `sh -c` never sees `~/.local/bin`, where Hermes' installer puts
///   the command for a normal user. Every one-shot CLI call exited 127.
/// - S15-F3: a multi-word "Hermes binary" override was quoted as ONE command
///   name.
///
/// The exec tests run the composed command in a real local `/bin/sh` with a
/// throwaway `$HOME` and a bare system PATH — the same situation as the
/// remote non-login shell — so they prove the command runs, not just that
/// the string looks right.
@Suite struct RemoteHermesResolutionR08Tests {

    private static func transport(hint: String? = nil, remoteHome: String? = nil) -> SSHTransport {
        SSHTransport(
            contextID: UUID(),
            config: SSHConfig(host: "box.local", remoteHome: remoteHome, hermesBinaryHint: hint),
            displayName: "Box"
        )
    }

    /// A temp `$HOME` with an executable script at `relativePath` that
    /// prints its name and argv.
    private static func homeWithScript(at relativePath: String, name: String) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r08-\(UUID().uuidString)")
        let script = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"\(name) $*\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return home
    }

    /// Runs `command` the way the remote does: `/bin/sh -c` with no login
    /// files and the bare system PATH.
    private static func runNonLogin(_ command: String, home: URL) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - S15-F1

    @Test func everyRemoteCommandAppendsTheInstallDirs() {
        let cmd = Self.transport().remoteShellCommand(executable: "hermes", args: ["cron", "list"])
        #expect(cmd == HermesConfigReader.pathFallback + "; "
            + "COLUMNS=400 \"hermes\" \"-p\" \"default\" \"cron\" \"list\"")
        #expect(cmd.hasPrefix("PATH=\"$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin\"; "))
        // The PATH line goes before the `cd`, so it covers the whole line.
        let withCwd = Self.transport().remoteShellCommand(executable: "hermes", args: ["acp"], cwd: "/srv/p")
        #expect(withCwd.hasPrefix(HermesConfigReader.pathFallback + "; cd \"/srv/p\"; "))
    }

    /// `runProcess` hands the command to ssh single-quoted, and the remote
    /// login shell runs `sh -c '<cmd>'`: two shells, like here.
    private static func throughLoginShell(_ cmd: String) -> String {
        "sh -c '" + cmd.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The failure itself, then the fix: bare `hermes` in `~/.local/bin` is
    /// "not found" (127) without the prelude and runs with it.
    @Test func bareHermesInLocalBinRunsInANonLoginShell() throws {
        let home = try Self.homeWithScript(at: ".local/bin/hermes", name: "hermes")
        defer { try? FileManager.default.removeItem(at: home) }
        let t = Self.transport()

        let bare = t.composedRemoteCommand(executable: "hermes", args: ["config", "show"])
        #expect(try Self.runNonLogin(bare, home: home).0 == 127)

        let fixed = t.remoteShellCommand(executable: "hermes", args: ["config", "show"])
        let (code, out) = try Self.runNonLogin(Self.throughLoginShell(fixed), home: home)
        #expect(code == 0)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "hermes -p default config show")
    }

    /// The install dirs come AFTER the shell's own PATH, so a `hermes` that
    /// already resolved (a venv, a root install in /usr/local/bin) keeps
    /// winning; they only fill in when nothing else is found.
    @Test func theFallbackNeverShadowsAHermesThatAlreadyResolved() throws {
        let home = try Self.homeWithScript(at: ".local/bin/hermes", name: "local-bin")
        defer { try? FileManager.default.removeItem(at: home) }
        let own = home.appendingPathComponent("venv/bin/hermes")
        try FileManager.default.createDirectory(
            at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"venv $*\"\n".write(to: own, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.path)

        let cmd = Self.transport().remoteShellCommand(executable: "hermes", args: ["--version"])
        let withOwn = "PATH=\"\(own.deletingLastPathComponent().path):$PATH\"; " + cmd
        #expect(try Self.runNonLogin(withOwn, home: home).1.hasPrefix("venv"))
        // …and with nothing on PATH the fallback still finds ~/.local/bin.
        #expect(try Self.runNonLogin(cmd, home: home).1.hasPrefix("local-bin"))
    }

    // MARK: - S15-F3

    @Test func onlyAMultiWordHintIsAShellFragment() {
        #expect(HermesPathSet.binaryHintIsShellFragment("docker compose exec hermes hermes"))
        #expect(HermesPathSet.binaryHintIsShellFragment("env\tFOO=1 hermes"))
        #expect(!HermesPathSet.binaryHintIsShellFragment("/home/u/.local/bin/hermes"))
        #expect(!HermesPathSet.binaryHintIsShellFragment("  hermes  "))
        #expect(!HermesPathSet.binaryHintIsShellFragment(nil))
    }

    @Test func aWrapperHintIsEmittedAsWordsAndStillPinned() {
        let hint = "docker compose exec hermes hermes"
        let cmd = Self.transport(hint: hint).composedRemoteCommand(executable: hint, args: ["acp"])
        #expect(cmd == "COLUMNS=400 docker compose exec hermes hermes \"-p\" \"default\" \"acp\"")
        // As an argument too (`env PYTHONUNBUFFERED=1 <hermes> auth add …`).
        let viaEnv = Self.transport(hint: hint).composedRemoteCommand(
            executable: "/usr/bin/env", args: ["PYTHONUNBUFFERED=1", hint, "auth", "add", "nous"])
        #expect(viaEnv == "COLUMNS=400 \"/usr/bin/env\" \"PYTHONUNBUFFERED=1\" docker compose exec hermes hermes \"auth\" \"add\" \"nous\"")
    }

    @Test func aSingleWordHintIsStillQuotedAsOnePath() {
        let hint = "~/tools/hermes"
        let cmd = Self.transport(hint: hint).composedRemoteCommand(executable: hint, args: ["acp"])
        #expect(cmd == "COLUMNS=400 \"$HOME/tools/hermes\" \"-p\" \"default\" \"acp\"")
    }

    /// End to end: the wrapper runs with the rest of the argv after it.
    @Test func aWrapperHintRunsInTheShell() throws {
        let home = try Self.homeWithScript(at: "bin/wrap", name: "wrap")
        defer { try? FileManager.default.removeItem(at: home) }
        let hint = home.path + "/bin/wrap exec hermes"
        let cmd = Self.transport(hint: hint, remoteHome: "~/.hermes/profiles/work")
            .remoteShellCommand(executable: hint, args: ["cron", "list"])
        let (code, out) = try Self.runNonLogin(Self.throughLoginShell(cmd), home: home)
        #expect(code == 0)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "wrap exec hermes cron list")
    }

    @Test func aWrapperHintCountsAsResolvable() {
        let ctx = ServerContext(
            id: UUID(), displayName: "Box",
            kind: .ssh(SSHConfig(host: "box.local", hermesBinaryHint: "/usr/bin/docker compose exec hermes hermes")))
        // Used to be `test -e "/usr/bin/docker compose exec…"` over SSH,
        // which is always false: chat showed "Hermes Not Found". No I/O now.
        #expect(ctx.hermesBinaryProbablyResolvable())
    }
}
