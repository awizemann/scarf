import Testing
import Foundation
import ScarfCore
@testable import scarf

/// The wake sweep's verify runs seconds after its `-O exit`, when a chat may
/// already have built a fresh master: it must only look. Driven against a
/// scripted ssh that logs every invocation.
@Suite struct WakeRecoveryVerifyTests {

    /// Runs `verifiedRecovery` against a scripted ssh; returns its outcome and
    /// whether it issued `-O exit`.
    private static func verify(masterPresent: Bool, probeExit: Int) throws -> (WakeReconnectMetrics.HostOutcome, Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("ssh").path
        let log = dir.appendingPathComponent("log")
        let script = """
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        case "$*" in
          *"-O check"*) exit \(masterPresent ? 0 : 255) ;;
          *"-O exit"*) exit 0 ;;
          *) exit \(probeExit) ;;
        esac
        """
        try script.write(toFile: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)

        let transport = SSHTransport(
            contextID: ServerID(),
            config: SSHConfig(host: "wake-\(UUID().uuidString).invalid", user: "nobody"),
            displayName: "wake-test",
            sshBinary: binary
        )
        let outcome = WakeReconnectMetrics.verifiedRecovery(of: transport)
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (outcome, logged.contains("-O exit"))
    }

    @Test func aMasterThatDoesNotAnswerIsAFailedRecoveryAndIsLeftAlone() throws {
        let (outcome, issuedExit) = try Self.verify(masterPresent: true, probeExit: 255)
        #expect(outcome == .recoveryFailed)
        #expect(!issuedExit, "the verify tore down a master a chat may have just rebuilt")
    }

    @Test func noMasterMeansTheTeardownWorked() throws {
        let (outcome, issuedExit) = try Self.verify(masterPresent: false, probeExit: 0)
        #expect(outcome == .recovered)
        #expect(!issuedExit)
    }

    /// A chat reconnected in between: success too, and untouched.
    @Test func aFreshAnsweringMasterCountsAsRecovered() throws {
        let (outcome, issuedExit) = try Self.verify(masterPresent: true, probeExit: 0)
        #expect(outcome == .recovered)
        #expect(!issuedExit)
    }
}
