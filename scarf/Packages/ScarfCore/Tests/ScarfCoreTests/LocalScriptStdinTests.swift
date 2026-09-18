#if !os(iOS)
import Testing
import Foundation
@testable import ScarfCore

/// A local script travels on stdin, never in argv.
///
/// `SSHScriptRunner.runLocally` ran `/bin/sh -c <script>`, which puts the
/// whole script in the process's argv — readable in `ps` by every user on
/// the Mac for as long as it runs. Scripts carry Live Voice's SDP offer (ICE
/// credentials) and the text sent to Hermes Voice TTS. It now runs
/// `/bin/sh -s` with the script on stdin, the shape the SSH path already had.
///
/// The feed is non-blocking and pumped from the run loop, so a script larger
/// than the pipe buffer cannot park the run before its timeout (charter C10).
@Suite("Local scripts go through stdin, not argv")
struct LocalScriptStdinTests {

    /// The property itself: the shell's own argv, as `ps` shows it, must not
    /// contain the script. Under `-c` the marker is right there.
    @Test("the running shell's argv does not contain the script")
    func argvDoesNotCarryTheScript() async throws {
        let marker = "scarf-secret-\(UUID().uuidString)"
        // `echo "$(…)"`, not a bare `ps`: sh execs a script's last simple
        // command in place, which would make `$$` the `ps` itself.
        let script = """
            # \(marker)
            echo "$(/bin/ps -o args= -p $$)"
            """
        let result = try await LocalTransport().streamScript(script, timeout: 10)
        #expect(result.exitCode == 0)
        let argv = String(decoding: result.stdout, as: UTF8.self)
        #expect(argv.contains("sh"), "ps printed nothing useful: \(argv)")
        #expect(!argv.contains(marker), """
            The script is in the shell's argv, so any local user can read it \
            with `ps`: \(argv)
            """)
    }

    @Test("a heredoc, quotes and $-expansions arrive byte-for-byte")
    func scriptArrivesIntact() async throws {
        let script = #"""
            NAME='it'"'"'s'
            cat <<EOF
            single: $NAME
            double: "quoted \$literal"
            EOF
            cat <<'RAW'
            raw: $NAME "x" 'y' `z`
            RAW
            printf '%s\n' "tail: $((1 + 2))"
            """#
        let result = try await LocalTransport().streamScript(script, timeout: 10)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == """
            single: it's
            double: "quoted $literal"
            raw: $NAME "x" 'y' `z`
            tail: 3

            """)
    }

    /// Bigger than any pipe buffer, so the feed has to cross several ticks.
    @Test("a script larger than the pipe buffer runs to the end")
    func largeScriptCompletes() async throws {
        let padding = String(repeating: "# \(String(repeating: "x", count: 100))\n", count: 3000)
        let script = padding + "echo done\n"
        #expect(script.utf8.count > 256 * 1024)
        let result = try await LocalTransport().streamScript(script, timeout: 20)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
    }

    /// `sh -s` stops reading while `sleep` runs, so the unread tail fills the
    /// pipe. A blocking write would wait out the whole sleep and never reach
    /// the timeout; the pump lets the 1 s timeout fire. The 30 s bound is a
    /// ceiling only the regression pays (it takes 60 s), not a bet on how
    /// fast a loaded machine escalates a kill.
    @Test("a stalled shell with an unread tail still times out on schedule")
    func stalledFeedStillTimesOut() async throws {
        let padding = String(repeating: "# \(String(repeating: "x", count: 100))\n", count: 3000)
        let script = "sleep 60\n" + padding + "echo unreachable\n"
        let start = Date()
        do {
            _ = try await LocalTransport().streamScript(script, timeout: 1)
            Issue.record("the script ran to the end instead of timing out")
        } catch let TransportError.other(message) {
            #expect(message.hasPrefix("Script timed out"), "\(message)")
        }
        #expect(Date().timeIntervalSince(start) < 30, "the timeout waited on the stdin write")
    }

    /// Source pin: the local arm must not go back to putting the script in
    /// argv. Calibrated — the old spelling is matched by the same needle.
    @Test("runLocally spawns `/bin/sh -s` with a stdin pipe")
    func runLocallyUsesStdin() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // …/ScarfCoreTests
                .deletingLastPathComponent()   // …/Tests
                .deletingLastPathComponent()   // …/ScarfCore
                .appendingPathComponent("Sources/ScarfCore/Transport/SSHScriptRunner.swift"),
            encoding: .utf8)
        let start = try #require(source.range(of: "private static func runLocally("),
                                 "runLocally is gone — re-point this pin")
        let end = try #require(source.range(of: "#endif // !os(iOS)", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        func putsScriptInArgv(_ text: String) -> Bool {
            text.range(of: #"arguments\s*=\s*\[\s*"-c""#, options: .regularExpression) != nil
        }
        #expect(putsScriptInArgv(#"proc.arguments = ["-c", script]"#), "needle no longer matches the old form")
        #expect(!putsScriptInArgv(body), "runLocally passes the script in argv again")
        #expect(body.contains(#"proc.arguments = ["-s"]"#))
        #expect(body.contains("proc.standardInput = stdinPipe"))
        #expect(body.contains("ScriptFeeder("))
        // P43b: the drain is installed before the feed.
        let drainAt = try #require(body.range(of: "Process.startDraining("))
        let feedAt = try #require(body.range(of: "ScriptFeeder("))
        #expect(drainAt.lowerBound < feedAt.lowerBound)
    }
}
#endif
