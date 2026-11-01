import Testing
import Foundation
@testable import ScarfCore

/// `recoverControlMasterIfDead` and `checkControlMaster` against a scripted
/// ssh: it answers `-O check` as told, plays the muxed probe as told, and logs
/// every invocation, so a test sees whether `-O exit` was issued.
#if os(macOS)
@Suite struct SSHControlMasterProbeTests {

    /// A throwaway `ssh` script and the log it writes.
    struct FakeSSH {
        let dir: URL
        var binary: String { dir.appendingPathComponent("ssh").path }
        var log: String { (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? "" }
        var issuedExit: Bool { log.contains("-O exit") }
        var ranProbe: Bool { log.split(separator: "\n").contains { $0.hasSuffix(" true") } }

        /// `probe`: the shell line the muxed `true` runs.
        init(masterPresent: Bool = true, probe: String) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-ssh-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            echo "$*" >> "\(dir.path)/log"
            case "$*" in
              *"-O check"*) exit \(masterPresent ? 0 : 255) ;;
              *"-O exit"*) exit 0 ;;
              *) \(probe) ;;
            esac
            """
            try script.write(to: URL(fileURLWithPath: binary), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// A transport on an endpoint no other test uses; its breaker is reset
    /// by the caller's `defer`.
    private static func transport(_ ssh: FakeSSH) -> (SSHTransport, String) {
        let config = SSHConfig(host: "probe-\(UUID().uuidString).invalid", user: "nobody")
        let transport = SSHTransport(
            contextID: ServerID(), config: config, displayName: "probe-test", sshBinary: ssh.binary)
        return (transport, transport.gateKey)
    }

    private static func openBreaker(_ key: String) {
        for _ in 0..<3 { SSHConnectionGate.shared.recordFailure(key) }
        #expect(SSHConnectionGate.shared.isOpen(key))
    }

    // MARK: - Recovery (audit P2 #2)

    /// The bug: an open breaker refused the probe, and "no result" read as
    /// a dead session, so a healthy master shared by every chat was closed.
    @Test func anOpenBreakerNeverClosesAHealthyMaster() throws {
        let ssh = try FakeSSH(probe: "exit 0")
        defer { ssh.cleanup() }
        let (transport, key) = Self.transport(ssh)
        defer { SSHConnectionGate.shared.reset(key) }
        Self.openBreaker(key)

        #expect(transport.recoverControlMasterIfDead() == .alive)
        #expect(ssh.ranProbe, "the breaker refused the probe")
        #expect(!ssh.issuedExit, "a healthy master was closed behind an open breaker")
    }

    @Test func aProbeThatRanAndFailedStillClosesTheMaster() throws {
        let ssh = try FakeSSH(probe: "exit 255")
        defer { ssh.cleanup() }
        let (transport, key) = Self.transport(ssh)
        defer { SSHConnectionGate.shared.reset(key) }

        #expect(transport.recoverControlMasterIfDead() == .recovered)
        #expect(ssh.issuedExit)
    }

    /// The breaker open as well: a corpse is the usual reason it opened, and
    /// recovery is what gets the host out of that.
    @Test func aDeadMasterIsStillClosedBehindAnOpenBreaker() throws {
        let ssh = try FakeSSH(probe: "exit 255")
        defer { ssh.cleanup() }
        let (transport, key) = Self.transport(ssh)
        defer { SSHConnectionGate.shared.reset(key) }
        Self.openBreaker(key)

        #expect(transport.recoverControlMasterIfDead() == .recovered)
        #expect(ssh.issuedExit)
    }

    @Test func aHungProbeStillClosesTheMaster() throws {
        let ssh = try FakeSSH(probe: "exec sleep 30")
        defer { ssh.cleanup() }
        let (transport, key) = Self.transport(ssh)
        defer { SSHConnectionGate.shared.reset(key) }

        #expect(transport.recoverControlMasterIfDead(probeTimeout: 0.5) == .recovered)
        #expect(ssh.issuedExit)
    }

    @Test func noMasterIsLeftAlone() throws {
        let ssh = try FakeSSH(masterPresent: false, probe: "exit 0")
        defer { ssh.cleanup() }
        let (transport, key) = Self.transport(ssh)
        defer { SSHConnectionGate.shared.reset(key) }

        #expect(transport.recoverControlMasterIfDead() == .noMaster)
        #expect(!ssh.ranProbe)
        #expect(!ssh.issuedExit)
    }

    // MARK: - Read-only check (audit P2 #3)

    @Test func checkingADeadMasterNeverTearsItDown() throws {
        let ssh = try FakeSSH(probe: "exit 255")
        defer { ssh.cleanup() }
        let (transport, key) = Self.transport(ssh)
        defer { SSHConnectionGate.shared.reset(key) }

        #expect(transport.checkControlMaster() == .dead)
        #expect(!ssh.issuedExit, "a read-only check issued -O exit")
    }
}
#endif
