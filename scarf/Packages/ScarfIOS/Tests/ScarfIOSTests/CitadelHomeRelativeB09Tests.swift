import Testing
import Foundation
@testable import ScarfIOS

/// S15-F4 — a `~/` argument on the iOS transport must reach the remote
/// command as the user's home, not as a literal `~` directory. `git -C
/// '~/projects/x'` failed, so ScarfGo never showed the branch chip for a
/// project installed under the default `~/projects`.
@Suite struct CitadelHomeRelativeB09Tests {

    @Test func homeRelativeTokensBecomeDoubleQuotedHOME() {
        let line = CitadelServerTransport.commandLine(
            executable: "git", args: ["-C", "~/projects/x", "rev-parse"], fragment: nil)
        #expect(line == #"git -C "$HOME/projects/x" rev-parse"#)
        #expect(CitadelServerTransport.commandLine(executable: "ls", args: ["~"], fragment: nil)
            == #"ls "$HOME""#)
        // A `~` that does not start the token is not a home path.
        #expect(CitadelServerTransport.commandLine(executable: "echo", args: ["a~/b"], fragment: nil)
            == "echo 'a~/b'")
    }

    /// Run the built line through a real `/bin/sh` (the remote side wraps
    /// it the same way) with a scratch HOME: the path expands, and nothing
    /// in the rest of it (spaces, quotes, `$(…)`, backticks) is interpreted.
    @Test func theBuiltLineExpandsHomeAndNothingElse() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b09-\(UUID().uuidString)").path
        let arg = #"~/My Projects/it's "x" $(touch pwned) `id` $USER\n"#
        let line = CitadelServerTransport.commandLine(executable: "printf", args: ["%s", arg], fragment: nil)
        let wrapped = CitadelServerTransport.viaPOSIXShell(line)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", wrapped]
        proc.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(proc.terminationStatus == 0)
        #expect(printed == home + #"/My Projects/it's "x" $(touch pwned) `id` $USER\n"#)
        #expect(!FileManager.default.fileExists(
            atPath: FileManager.default.temporaryDirectory.appendingPathComponent("pwned").path))
    }
}

/// S15-F1 — a single-word argument with a `$` in it must reach the command
/// unchanged. `shellJoin` used to treat `$` as safe, so the remote shell
/// expanded `Cost$5` to `Cost` and `$FOO` to nothing.
@Suite struct CitadelDollarQuotingC02Tests {

    @Test func dollarWordsAreQuoted() {
        #expect(CitadelServerTransport.shellJoin(["Cost$5"]) == "'Cost$5'")
        #expect(CitadelServerTransport.shellJoin(["$FOO"]) == "'$FOO'")
        #expect(CitadelServerTransport.shellJoin(["plain-word"]) == "plain-word")
    }

    /// Through a real `/bin/sh`, wrapped the way the transport runs it.
    @Test func dollarWordsSurviveARealShell() throws {
        let args = ["Cost$5", "$FOO", "${HOME}", "a$(echo x)b"]
        let line = CitadelServerTransport.commandLine(
            executable: "printf", args: ["%s|"] + args, fragment: nil)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", CitadelServerTransport.viaPOSIXShell(line)]
        proc.environment = ["HOME": "/nonexistent-home", "FOO": "expanded", "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(proc.terminationStatus == 0)
        #expect(printed == args.map { $0 + "|" }.joined())
    }
}
