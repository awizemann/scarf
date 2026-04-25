import Testing
import Foundation
@testable import ScarfCore

/// Exercises M3's changes to the `ServerTransport` surface: the new
/// `streamLines(_:args:)` method, the platform-gated `makeProcess`,
/// the `ServerContext.sshTransportFactory` injection point, and the
/// HermesLogService refactor that drives remote tailing through
/// `streamLines` instead of a raw `Process` + `Pipe`.
///
/// **`.serialized` is mandatory.** Several tests set the static
/// `ServerContext.sshTransportFactory` + restore in `defer`. Running
/// them in parallel (swift-testing's default) makes the factory a
/// race hazard — one test's scripted transport gets read by the
/// other, producing confusing "wrong log line" failures.
@Suite(.serialized) struct M3TransportTests {

    // MARK: - streamLines: LocalTransport

    @Test func localStreamLinesYieldsOneLinePerNewline() async throws {
        // `echo -e` is not portable between BSD and GNU `echo`, so we
        // use `/bin/sh -c 'printf ...'` which is deterministic on both.
        // LocalTransport's streamLines should yield three lines when
        // the subprocess emits "a\nb\nc\n".
        let transport = LocalTransport()
        let stream = transport.streamLines(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\nb\\nc\\n'"]
        )
        var collected: [String] = []
        for try await line in stream {
            collected.append(line)
        }
        #expect(collected == ["a", "b", "c"])
    }

    @Test func localStreamLinesFinishesOnEOFWithoutTrailingNewline() async throws {
        // If the subprocess emits "a\nb" (no trailing newline), we
        // yield "a" and DROP "b" — the stream framer treats partial
        // trailing content as unterminated. This is the documented
        // behaviour and matches what the HermesLogService tail path
        // sees over SSH.
        let transport = LocalTransport()
        let stream = transport.streamLines(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\nb'"]
        )
        var collected: [String] = []
        for try await line in stream {
            collected.append(line)
        }
        #expect(collected == ["a"])
    }

    @Test func localStreamLinesSurfacesNonZeroExit() async throws {
        let transport = LocalTransport()
        let stream = transport.streamLines(
            executable: "/bin/sh",
            args: ["-c", "printf 'a\\n'; exit 3"]
        )
        var collected: [String] = []
        var thrown: Error?
        do {
            for try await line in stream {
                collected.append(line)
            }
        } catch {
            thrown = error
        }
        #expect(collected == ["a"])
        guard let err = thrown as? TransportError else {
            Issue.record("expected TransportError, got \(String(describing: thrown))")
            return
        }
        if case .commandFailed(let exit, _) = err {
            #expect(exit == 3)
        } else {
            Issue.record("expected .commandFailed, got \(err)")
        }
    }

    // MARK: - sshTransportFactory injection

    // MARK: - sshTransportFactory injection + HermesLogService remote tail
    //
    // The factory-touching tests that used to live in M3 (3 factory-injection
    // tests + 2 HermesLogService remote-tail tests) were moved into
    // `M5FeatureVMTests` (the canonical `.serialized` factory suite) in
    // v2.5. Co-locating them eliminates the cross-suite race we hit during
    // pre-release verification: M3 + M5 each held `.serialized` internally
    // but ran in parallel with each other, clobbering the static. The tests
    // themselves are unchanged in shape, just relocated.
}
