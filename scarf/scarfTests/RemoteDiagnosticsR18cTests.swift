import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R18c, the Remote Diagnostics script (T6-F2, T6-F4). The script runs on
/// the remote's `/bin/sh -s`; here it runs on the local `/bin/sh` and
/// `/bin/dash` (Ubuntu's `/bin/sh`) in a throwaway `$HOME`.
@Suite struct RemoteDiagnosticsR18cTests {

    private static func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-r18c-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func executable(_ url: URL, _ body: String = "#!/bin/sh\n") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Runs the script on `<sh> -s` stdin, as `SSHScriptRunner` does, and
    /// returns `(stdout, exit status)`.
    private static func run(
        _ script: String, home: URL, sh: String = "/bin/sh", loginShell: String = "/bin/sh",
        path: String = "/usr/bin:/bin"
    ) throws -> (String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sh)
        proc.arguments = ["-s"]
        proc.environment = ["HOME": home.path, "PATH": path, "SHELL": loginShell]
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        return (out, proc.terminationStatus)
    }

    private static func row(_ key: String, in out: String) -> String? {
        out.split(separator: "\n").first { $0.hasPrefix(key + "|") }.map(String.init)
    }

    // MARK: - T6-F2: no rc files sourced into sh

    /// A zsh login shell whose `.zprofile`/`.zshenv` use zsh-only syntax:
    /// sourced into dash they ended the script, and every check after them
    /// read as FAILED. Now dash runs to `__END__`, and the PATH the zsh
    /// profile sets is still what the login checks see.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/dash")))
    func zshOnlyRcFilesNoLongerEndTheScriptUnderDash() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tools = home.appendingPathComponent("zsh-tools")
        try Self.executable(tools.appendingPathComponent("hermes"))
        try "typeset -U path\npath=(\(tools.path) $path)\n"
            .write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "setopt no_nomatch\nplugins=(git)\n"
            .write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)

        // The old sourcing loop, proven to die under dash with these files.
        let oldLoop = #"for rc in "$HOME/.zshenv" "$HOME/.zprofile"; do [ -f "$rc" ] && . "$rc" 2>/dev/null; done; echo AFTER"#
        let (oldOut, oldCode) = try Self.run(oldLoop + "\n", home: home, sh: "/bin/dash")
        #expect(oldCode != 0)
        #expect(!oldOut.contains("AFTER"))

        let script = RemoteDiagnosticsViewModel.buildScript(hermesHome: "~/.hermes")
        #expect(!script.contains(". \"$rc\""))
        let (out, code) = try Self.run(script, home: home, sh: "/bin/dash", loginShell: "/bin/zsh")
        #expect(code == 0, "\(out)")
        #expect(out.contains("__END__"))
        #expect(Self.row("hermesBinaryLogin", in: out) == "hermesBinaryLogin|PASS|\(tools.path)/hermes")
        #expect(Self.row("pgrepAvailable", in: out)?.hasPrefix("pgrepAvailable|PASS|") == true)
        #expect(Self.row("sqlite3Installed", in: out)?.hasPrefix("sqlite3Installed|PASS|") == true)
    }

    // MARK: - T6-F4: the saved Hermes binary

    /// A typed wrapper (`docker compose exec hermes hermes`) is checked by
    /// its first word, on the same PATH the runtime uses. Without a saved
    /// binary, a missing `hermes` still fails as before.
    @Test func aWrapperHintIsCheckedByItsFirstWord() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.executable(home.appendingPathComponent(".local/bin/docker"))

        let hinted = RemoteDiagnosticsViewModel.buildScript(
            hermesHome: "~/.hermes", binaryHint: "docker compose exec hermes hermes")
        let (out, _) = try Self.run(hinted, home: home)
        #expect(Self.row("hermesBinaryNonLogin", in: out)
            == "hermesBinaryNonLogin|PASS|\(home.path)/.local/bin/docker")

        let bare = RemoteDiagnosticsViewModel.buildScript(hermesHome: "~/.hermes")
        let (bareOut, _) = try Self.run(bare, home: home)
        #expect(Self.row("hermesBinaryNonLogin", in: bareOut)?.hasPrefix("hermesBinaryNonLogin|FAIL|hermes not on") == true)
        #expect(Self.row("hermesBinaryLogin", in: bareOut)?.hasPrefix("hermesBinaryLogin|FAIL|hermes not found") == true)
    }

    /// A path Test Connection found is one word, spaces and all, and it is
    /// found even outside the install directories.
    @Test func aProbedPathHintIsOneWord() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hermes = home.appendingPathComponent("Hermes Tools/bin/hermes")
        try Self.executable(hermes)
        let script = RemoteDiagnosticsViewModel.buildScript(
            hermesHome: "~/.hermes", binaryHint: hermes.path, binaryHintIsPath: true)
        let (out, _) = try Self.run(script, home: home)
        #expect(Self.row("hermesBinaryNonLogin", in: out) == "hermesBinaryNonLogin|PASS|\(hermes.path)")
        #expect(Self.row("hermesBinaryLogin", in: out) == "hermesBinaryLogin|PASS|\(hermes.path)")
    }

    /// A saved binary that is gone fails and names itself — and the login
    /// check does not fall back to some other `hermes` the runtime would
    /// never run. `$` and quotes in the hint reach the script as typed.
    @Test func aMissingHintFailsAndNamesItself() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.executable(home.appendingPathComponent(".local/bin/hermes"))
        let script = RemoteDiagnosticsViewModel.buildScript(
            hermesHome: "~/.hermes", binaryHint: "~/gone/$HERMES \"x\"")
        let (out, code) = try Self.run(script, home: home)
        #expect(code == 0)
        #expect(Self.row("hermesBinaryNonLogin", in: out)?
            .hasPrefix("hermesBinaryNonLogin|FAIL|saved Hermes binary \"~/gone/$HERMES \"x\"\" not on") == true, "\(out)")
        #expect(Self.row("hermesBinaryLogin", in: out)?
            .hasPrefix("hermesBinaryLogin|FAIL|saved Hermes binary") == true, "\(out)")
    }

    /// A `~/` hint is expanded the way the runtime's `$HOME/` rewrite does.
    @Test func aTildeHintExpands() throws {
        let home = try Self.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hermes = home.appendingPathComponent("opt/hermes")
        try Self.executable(hermes)
        let script = RemoteDiagnosticsViewModel.buildScript(hermesHome: "~/.hermes", binaryHint: "~/opt/hermes")
        let (out, _) = try Self.run(script, home: home)
        #expect(Self.row("hermesBinaryNonLogin", in: out) == "hermesBinaryNonLogin|PASS|\(hermes.path)")
    }

    /// TestConnectionProbe and Diagnostics share one login-PATH line.
    @Test func bothScriptsUseTheSameLoginPathBorrow() {
        let probe = TestConnectionProbe.probeScript(config: SSHConfig(host: "box"))
        let diag = RemoteDiagnosticsViewModel.buildScript(hermesHome: "~/.hermes")
        #expect(probe.contains(TestConnectionProbe.loginPathBorrow))
        #expect(diag.contains(TestConnectionProbe.loginPathBorrow))
    }
}
