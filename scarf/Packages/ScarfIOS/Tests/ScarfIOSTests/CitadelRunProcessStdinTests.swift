import Testing
import Foundation

/// `t-c7a7b1d4`: `CitadelServerTransport.runProcess`/`asyncRunProcess` used to
/// throw "does not support stdin yet" whenever a caller passed non-nil
/// `stdin`, even though `runExec`/`execArms` had already grown a full stdin
/// write arm for `streamScript` (round-5 P48b write task, reworked in the
/// voice merge c7f2cc26). There is nothing process-specific about that write
/// arm — it is `Self.writeStdin` writing chunks to the exec channel's
/// outbound stream — so `runProcess` should just plumb its `stdin` through
/// the same path instead of rejecting it. Code-scan style (no fake SSH
/// channel exists for a full end-to-end exec test, matching the convention
/// `CitadelExecChannelP48bTests` and `CitadelStreamScriptStdinTests` use).
@Suite("iOS runProcess plumbs stdin through instead of rejecting it")
struct CitadelRunProcessStdinTests {

    private static func transportSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfIOSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfIOS package root
            .appendingPathComponent("Sources/ScarfIOS/CitadelServerTransport.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                      && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }

    @Test("the transport no longer rejects stdin on runProcess")
    func noStdinRejection() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(!code.contains("does not support stdin yet"), """
            runProcess/asyncRunProcess must not throw a "does not support \
            stdin yet" error now that runExec/execArms carries a full stdin \
            write arm — the message would be a lie.
            """)
    }

    @Test("runProcess forwards its stdin into asyncRunProcess")
    func runProcessForwardsStdin() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains(
            "try await self.asyncRunProcess(executable: executable, args: args, stdin: stdin, timeout: timeout)"))
    }

    @Test("the public async seam forwards stdin to the private worker instead of dropping it")
    func asyncSeamForwardsStdin() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains(
            "try await asyncRunProcessImpl(\n            executable: executable, args: args, stdin: stdin, timeout: timeout)"))
    }

    @Test("the private worker hands stdin to runExec, the one write path streamScript already uses")
    func privateWorkerForwardsStdinToRunExec() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains(
            "try await runExec(cmd, stdin: stdin, timeout: timeout, midStream: .exitMinusOne)"))
    }
}
