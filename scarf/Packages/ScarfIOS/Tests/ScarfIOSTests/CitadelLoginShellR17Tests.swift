#if canImport(Citadel)

import Testing
import Foundation
import ScarfCore
@testable import ScarfIOS

/// R17: the iOS exec strings reach the remote user's LOGIN shell, which may
/// be csh/tcsh. They are sh syntax (`VAR=value cmd`, `"$PATH:…"`), so they
/// now go through `/bin/sh -c '…'` like the Mac's SSHTransport. These run
/// the real command text under each shell locally — what an SSH server does
/// with an exec request is `$SHELL -c <string>`.
@Suite("iOS exec strings survive a csh login shell")
struct CitadelLoginShellR17Tests {

    #if os(macOS)
    private static let shells = ["/bin/sh", "/bin/zsh", "/bin/csh", "/bin/tcsh"]

    /// Run `command` the way sshd does for a user whose login shell is `shell`.
    private static func run(_ shell: String, _ command: String, stdin: Data? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The premise: the bare prefix form is what csh refuses.
    @Test func theUnwrappedPrefixFailsUnderCsh() throws {
        let bare = #"COLUMNS=400 PATH="$HOME/.local/bin:$PATH:$HOME/.hermes/bin" printenv COLUMNS"#
        let (status, _) = try Self.run("/bin/csh", bare)
        #expect(status != 0)
    }

    /// The process exec shape (`COLUMNS=… PATH=… <cmd>`), wrapped, runs
    /// under every shell and the assignments reach the command.
    @Test func theWrappedProcessCommandRunsUnderEveryShell() throws {
        let cmd = "COLUMNS=\(LocalTransport.wideColumns) "
            + #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH:$HOME/.hermes/bin" "#
            + CitadelServerTransport.commandLine(
                executable: "printenv", args: ["COLUMNS"], fragment: nil)
        for shell in Self.shells {
            let (status, output) = try Self.run(shell, CitadelServerTransport.viaPOSIXShell(cmd))
            #expect(status == 0, Comment(rawValue: "\(shell): \(output)"))
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "\(LocalTransport.wideColumns)",
                    Comment(rawValue: shell))
        }
    }

    /// The script exec (`… head -c N | /bin/sh`), wrapped, still runs the
    /// script it reads from stdin.
    @Test func theWrappedScriptCommandRunsUnderEveryShell() throws {
        let script = Data("echo \"it's $((6 * 7))\"\n".utf8)
        let cmd = CitadelServerTransport.viaPOSIXShell(
            CitadelServerTransport.streamScriptCommand(byteCount: script.count))
        for shell in Self.shells {
            let (status, output) = try Self.run(shell, cmd, stdin: script)
            #expect(status == 0, Comment(rawValue: "\(shell): \(output)"))
            #expect(output.contains("it's 42"), Comment(rawValue: "\(shell): \(output)"))
        }
    }

    /// The ACP launch (`cd …; PATH=… HERMES_HOME=… exec <bin> … acp`),
    /// wrapped, reaches the binary with its argv intact — including a
    /// project dir and a profile home with spaces.
    @Test func theWrappedACPCommandRunsUnderEveryShell() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf r17 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cmd = CitadelServerTransport.viaPOSIXShell(ACPClient.buildACPCommand(
            hermesBinary: "/bin/echo",
            home: "/home/u/.hermes/profiles/my work",
            projectCwd: dir.path))
        for shell in Self.shells {
            let (status, output) = try Self.run(shell, cmd)
            #expect(status == 0, Comment(rawValue: "\(shell): \(output)"))
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "acp",
                    Comment(rawValue: "\(shell): \(output)"))
        }
    }
    #endif

    /// The wrapper is one single-quoted word, so the inner command's own
    /// single quotes survive.
    @Test func theWrapperQuotesTheWholeCommandAsOneWord() {
        let wrapped = CitadelServerTransport.viaPOSIXShell("cd '/a b'; echo hi")
        #expect(wrapped == #"/bin/sh -c 'cd '\''/a b'\''; echo hi'"#)
    }

    /// Both iOS exec paths and the ACP launch go through it (code scan,
    /// comments dropped): there is no SSH server to run them against here.
    @Test func everyExecPathIsWrapped() throws {
        func code(_ file: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ScarfIOS/\(file)")
            return try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let transport = try code("CitadelServerTransport.swift")
        #expect(transport.contains("let wrapped = Self.viaPOSIXShell(cmd)"))
        #expect(transport.contains("runExec(wrapped, stdin: stdin, timeout: timeout, midStream: .exitMinusOne)"))
        #expect(transport.contains("runExec(Self.viaPOSIXShell(cmd), stdin: stdin, timeout: timeout, midStream: .typedError)"))
        let acp = try code("ACPClient+iOS.swift")
        #expect(acp.contains("let command = CitadelServerTransport.viaPOSIXShell(buildACPCommand("))
        #expect(acp.contains("hermesBinary: context.paths.hermesBinaryShellWord"))
    }
}

#endif
