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
