import Testing
import Foundation
@testable import ScarfCore

/// The stdin feeder that pushes a script into `/bin/sh -s`.
///
/// The bug these pin: a write error other than EAGAIN/EPIPE used to `break`
/// straight into `finish()`, which closes the pipe — so the shell got a
/// TRUNCATED script, ran it as if it were complete, and the run reported
/// that output as the caller's own result.
#if os(macOS)
@Suite struct ScriptFeederFailureTests {

    @Test func aShortWriteRecordsItsErrno() throws {
        // A read-only descriptor: every write fails with EBADF, immediately
        // and deterministically — the "child is still there, but the script
        // never arrived" shape.
        let fd = open("/dev/null", O_RDONLY)
        try #require(fd >= 0)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let feeder = SSHScriptRunner.ScriptFeeder(handle: handle, script: "echo hello\n")
        feeder.pump()
        #expect(feeder.isDone)
        #expect(feeder.failure == EBADF)
    }

    @Test func afullWriteRecordsNoFailure() throws {
        let pipe = Pipe()
        let feeder = SSHScriptRunner.ScriptFeeder(
            handle: pipe.fileHandleForWriting, script: "echo hello\n")
        feeder.pump()
        #expect(feeder.isDone)
        #expect(feeder.failure == nil)
        #expect(try pipe.fileHandleForReading.readToEnd() == Data("echo hello\n".utf8))
    }

    /// EPIPE stays exempt: the child is gone, nothing ran, and its own exit
    /// is what reports.
    @Test func aVanishedReaderIsNotAFeedFailure() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let feeder = SSHScriptRunner.ScriptFeeder(
            handle: pipe.fileHandleForWriting, script: "echo hello\n")
        feeder.pump()
        #expect(feeder.failure == nil)
    }

    @Test func aFeedFailureIsAConnectFailureNotAResult() {
        guard case .connectFailure(let reason) = SSHScriptRunner.feedFailure(errno: EBADF) else {
            Issue.record("a truncated script must never read as a completed run")
            return
        }
        #expect(reason.hasPrefix("failed to feed the script: "))
        #expect(reason.contains(String(cString: strerror(EBADF))))
    }
}
#endif
