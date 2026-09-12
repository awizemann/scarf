#if !os(iOS)
import Foundation
import Testing
@testable import ScarfCore

/// Round-5 P48, decisions 4 and 5: the two Mac transports stop carrying their
/// own drain and their own unbounded waits.
///
/// Every test here spawns a REAL child, because every defect being pinned is
/// a property of a real pipe and a real signal disposition — the shapes that
/// used to wedge a caller forever, held to short budgets so the suite stays
/// fast.
@Suite("Transport drain + bounded waits (P48)")
struct TransportDrainP48Tests {

    /// Source text with comment LINES removed.
    ///
    /// Every scan below is looking for a call, and each of these fixes left a
    /// comment naming the shape it removed — so a raw `contains` would match
    /// the explanation and the sweep would be red for the fix that closed it.
    /// Comment-only lines are dropped; a trailing comment on a code line
    /// stays, which is the conservative direction.
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Decision 4: one drain primitive

    /// `ProcessPipeDrainer` is deleted, not merely unused. A second drain
    /// implementation is how the two defects below survived a whole round of
    /// C10 work in `ProcessPipeDrain` without ever reaching the transports.
    @Test("no second drain implementation survives in ScarfCore")
    func onlyOneDrainPrimitive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ScarfCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ScarfCore
            .appendingPathComponent("Sources/ScarfCore")
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if Self.codeOnly(text).contains("ProcessPipeDrainer") {
                offenders.append(url.lastPathComponent)
            }
        }
        // A premise floor: an enumeration that walked nothing would report an
        // empty offender list just as happily (round-4 P43b).
        #expect(scanned > 100, "only \(scanned) ScarfCore sources scanned")
        #expect(offenders.isEmpty, "ProcessPipeDrainer still referenced in \(offenders)")
    }

    /// The headline. `ProcessPipeDrainer.Capture.wait()` was a bare
    /// `group.wait()` and the transports' overrun arm was
    /// `terminate()` → bare `waitUntilExit()`, so a child that ignores
    /// SIGTERM **and** leaves a grandchild holding the pipe's write end hung
    /// the TIMEOUT path forever — the one path that exists because something
    /// already went wrong.
    ///
    /// The child here is exactly that: `sh` with SIGTERM trapped to ignore,
    /// and a `sleep` grandchild that inherits stdout and outlives everything.
    /// Against the old code this call never returns. Against the new one the
    /// escalation reaches SIGKILL and `collect(grace:)` gives up on the
    /// inherited fd, so it comes back inside a few seconds.
    @Test("a SIGTERM-proof child holding an inherited pipe still ends the timeout arm", .timeLimit(.minutes(1)))
    func overrunArmIsBoundedEvenWhenTheChildIgnoresSIGTERM() throws {
        let start = Date()
        var threw: TransportError?
        do {
            _ = try LocalTransport().runProcess(
                executable: "/bin/sh",
                args: ["-c", "trap '' TERM; sleep 45 & sleep 45"],
                stdin: nil,
                timeout: 0.5
            )
        } catch let error as TransportError {
            threw = error
        }
        let elapsed = Date().timeIntervalSince(start)
        guard case .timeout = try #require(threw) else {
            Issue.record("expected TransportError.timeout, got \(String(describing: threw))")
            return
        }
        // 0.5 s budget + two 2 s signal graces + a 1 s drain grace ≈ 5.5 s
        // worst case. Anything near the 45 s the child asked for means an
        // unbounded wait is back.
        #expect(elapsed < 20, "timeout arm took \(elapsed)s")
    }

    // MARK: - The fd leaks

    /// Open descriptors in this process. `/dev/fd` is the cheap, exact
    /// measure P43b used for the same question.
    static func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// A spawn that passes no stdin used to build a `Pipe()` anyway and close
    /// only the arm guarded by `stdin != nil` — so the read end was never
    /// released on ANY path, once per spawn, for the life of the process.
    @Test("a stdin-less spawn leaks no descriptors")
    func stdinLessSpawnLeaksNothing() throws {
        let transport = LocalTransport()
        // Warm up: the first spawn allocates one-time machinery.
        _ = try transport.runProcess(
            executable: "/bin/echo", args: ["warm"], stdin: nil, timeout: 10)
        let before = Self.openFDCount()
        for _ in 0..<30 {
            _ = try transport.runProcess(
                executable: "/bin/echo", args: ["hi"], stdin: nil, timeout: 10)
        }
        let after = Self.openFDCount()
        // 30 spawns × 1 leaked read end = +30 against the old code; a couple
        // of descriptors of slack for unrelated machinery.
        #expect(after - before < 10, "fd count went \(before) → \(after)")
    }

    /// The launch-failure arm: `run()` threw, so there was no fork and
    /// Foundation closed nothing. Both stdin ends stayed open.
    @Test("a spawn that fails to launch leaks no descriptors")
    func failedLaunchLeaksNothing() throws {
        let transport = LocalTransport()
        _ = try? transport.runProcess(
            executable: "/nonexistent/warm", args: [], stdin: Data("x".utf8), timeout: 10)
        let before = Self.openFDCount()
        for _ in 0..<30 {
            _ = try? transport.runProcess(
                executable: "/nonexistent/binary",
                args: [],
                stdin: Data("payload".utf8),
                timeout: 10
            )
        }
        let after = Self.openFDCount()
        #expect(after - before < 10, "fd count went \(before) → \(after)")
    }

    /// Stdin still reaches the child — the pipe became conditional, and a
    /// conditional that got the condition backwards would be silent.
    @Test("stdin still arrives when there is stdin to send")
    func stdinStillReachesTheChild() throws {
        let result = try LocalTransport().runProcess(
            executable: "/bin/cat",
            args: [],
            stdin: Data("through the pipe\n".utf8),
            timeout: 10
        )
        #expect(result.exitCode == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "through the pipe\n")
    }

    // MARK: - Decision 5: the timeout is required

    /// The compile-time half of decision 5 cannot be asserted at runtime — a
    /// `nil` no longer type-checks — so what is pinned is that the signature
    /// stayed non-optional on every conformer the package can see.
    @Test("the transport signature takes a required timeout")
    func timeoutIsNotOptional() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScarfCore/Transport")
        for name in ["ServerTransport.swift", "LocalTransport.swift", "SSHTransport.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            #expect(
                !Self.codeOnly(text).contains("timeout: TimeInterval?"),
                "\(name) still declares an optional transport timeout")
        }
    }
}
#endif
