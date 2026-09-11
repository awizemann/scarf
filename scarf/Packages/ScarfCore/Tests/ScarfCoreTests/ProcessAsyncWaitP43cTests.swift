#if !os(iOS)
import Foundation
import os
import Testing
@testable import ScarfCore

/// Round-4 P43c: the synchronous reap must not be reachable from an `async`
/// function, and `ProcessPipeDrain.collect` must be a latch rather than a
/// check-then-set.
///
/// `Process.waitUntilExit(timeout:)` is a `Thread.sleep` poll loop. On a
/// cooperative-pool thread that is not slow, it is *stolen*: the pool has one
/// thread per core and cannot grow, so an `async` caller parked in there for
/// up to `remoteExtractTimeout` (300 s) takes a core away from every other
/// task in the process. ``Process/waitDrainingAsync(timeout:drain:drainGrace:)``
/// moves the block onto a detached task and suspends the caller instead.
///
/// The sweep below is the part that keeps holding: a future edit that reaches
/// for the synchronous spelling from an `async func` fails this suite.
@Suite("Async process waits (P43c)")
struct ProcessAsyncWaitP43cTests {

    // MARK: - The matcher

    /// The spellings that park a thread on a child. All three live on
    /// `Process` in `ProcessTimeout.swift`, which is the one file where they
    /// are ALLOWED to be called synchronously — it is the file that implements
    /// them, and `waitDrainingAsync` is a wrapper around exactly this.
    static let blockingSpellings = ["waitUntilExit(timeout:", ".waitDraining(", "waitUntilExit()"]

    /// Strip comments and string literals so the brace walk below sees code.
    ///
    /// Needed, not decorative: these sources are dense with doc comments that
    /// quote `waitDraining(` in prose, and with URLs whose `//` would otherwise
    /// eat the rest of a line. Handles `//`, `/* */` (nested, as Swift does),
    /// `"…"` with escapes, and `"""…"""`.
    static func stripped(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var i = 0
        var blockDepth = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if blockDepth > 0 {
                if c == "*", next == "/" { blockDepth -= 1; i += 2; continue }
                if c == "/", next == "*" { blockDepth += 1; i += 2; continue }
                if c == "\n" { out.append(c) }
                i += 1
                continue
            }
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" { blockDepth = 1; i += 2; continue }
            if c == "\"" {
                // Multi-line string?
                if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                    i += 3
                    while i < chars.count {
                        if chars[i] == "\\" { i += 2; continue }
                        if chars[i] == "\"", i + 2 < chars.count,
                           chars[i + 1] == "\"", chars[i + 2] == "\"" {
                            i += 3
                            break
                        }
                        if chars[i] == "\n" { out.append("\n") }
                        i += 1
                    }
                    continue
                }
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    // An interpolation can hold braces; keeping them balanced
                    // matters more than keeping them out, and `\(` … `)` uses
                    // parens, so skipping the whole literal is safe.
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\n" { break }
                    i += 1
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Every blocking spelling that appears inside the body of an `async`
    /// function declaration, as `"<function name>: <spelling>"`.
    ///
    /// The walk: find each `func` token, read forward to the `{` that opens
    /// its body (tracking parens so a default argument's braces cannot be
    /// mistaken for it), decide on the signature text whether it is `async`,
    /// then brace-match the body. The walk resumes INSIDE each body, so nested
    /// declarations get their own turn — and a synchronous helper nested
    /// inside an `async` function is still flagged, via its parent's body,
    /// which is right: it runs on the same stolen thread.
    static func blockingCallsInAsyncFunctions(in source: String) -> [String] {
        let text = Array(stripped(source))
        var findings: [String] = []
        var i = 0
        while i < text.count {
            guard text[i] == "f",
                  i + 4 < text.count,
                  String(text[i..<(i + 4)]) == "func",
                  (i == 0 || !(text[i - 1].isLetter || text[i - 1].isNumber || text[i - 1] == "_")),
                  !(text[i + 4].isLetter || text[i + 4].isNumber || text[i + 4] == "_")
            else { i += 1; continue }

            var j = i + 4
            var parens = 0
            var angle = 0
            var signature = ""
            var bodyStart: Int?
            while j < text.count {
                let c = text[j]
                if c == "(" { parens += 1 }
                if c == ")" { parens -= 1 }
                if c == "<" { angle += 1 }
                if c == ">" { angle = max(0, angle - 1) }
                if c == "{", parens == 0, angle == 0 { bodyStart = j; break }
                // A protocol requirement or a `func` with no body ends at a
                // newline that closes the signature; treat `;` as an end too.
                if c == ";" { break }
                signature.append(c)
                j += 1
            }
            guard let start = bodyStart else { i += 4; continue }

            var depth = 0
            var k = start
            var body = ""
            while k < text.count {
                if text[k] == "{" { depth += 1 }
                if text[k] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(text[k])
                k += 1
            }

            let name = signature
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(while: { $0 != "(" && $0 != "<" })
            let isAsync = signature.contains(" async ") || signature.contains(" async\n")
                || signature.contains(" async-> ") || signature.contains("async ->")
            if isAsync {
                for spelling in blockingSpellings where body.contains(spelling) {
                    findings.append("\(name): \(spelling)")
                }
            }
            // Continue INSIDE the body, so nested declarations get their turn.
            i = start + 1
        }
        return findings
    }

    // MARK: - Calibration (the P22 rule: a sweep is only as good as its matcher)

    @Test("the matcher recognises each shape and each near-miss")
    func matcherIsCalibrated() {
        // Hits.
        #expect(!Self.blockingCallsInAsyncFunctions(in: """
            func a() async throws {
                let (exited, _) = proc.waitDraining(timeout: 5, drain: drain)
            }
            """).isEmpty)
        #expect(!Self.blockingCallsInAsyncFunctions(in: """
            public func b(x: Int = 1) async -> Bool {
                proc.waitUntilExit(timeout: 3)
            }
            """).isEmpty)
        // Nested: the inner async declaration is its own subject.
        #expect(!Self.blockingCallsInAsyncFunctions(in: """
            func outer() {
                func inner() async {
                    _ = p.waitUntilExit(timeout: 1)
                }
            }
            """).isEmpty)

        // Near-misses.
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            func sync() throws {
                _ = proc.waitDraining(timeout: 5, pipes: [a])
            }
            """).isEmpty, "a synchronous function may call the synchronous form")
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            func a() async throws {
                _ = await proc.waitDrainingAsync(timeout: 5, drain: drain)
            }
            """).isEmpty, "the async form must not match")
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            /// See `proc.waitDraining(timeout:drain:)` for why.
            func a() async throws { try await x() }
            """).isEmpty, "a doc comment naming the helper is not a call")
        #expect(Self.blockingCallsInAsyncFunctions(in: #"""
            func a() async throws {
                log("proc.waitDraining(timeout: 5) is what this used to do")
            }
            """#).isEmpty, "a string literal quoting the helper is not a call")

        // The stripper does not eat code.
        let kept = Self.stripped("let u = \"https://x/y\" // note\nlet n = 1\n")
        #expect(kept.contains("let n = 1"))
        #expect(!kept.contains("note"))
    }

    // MARK: - The sweep

    static var scarfCoreSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .appendingPathComponent("Sources/ScarfCore")
    }

    @Test("no async function in ScarfCore blocks a cooperative thread on a child")
    func noSynchronousReapInAsyncCode() throws {
        let root = Self.scarfCoreSources
        #expect(FileManager.default.fileExists(atPath: root.path), "the sweep root moved")
        let walker = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "could not enumerate \(root.path)")

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // The file that IMPLEMENTS the helpers is where the synchronous
            // form is called on purpose: `waitDrainingAsync` is a wrapper
            // around it, from inside a detached task.
            if url.lastPathComponent == "ProcessTimeout.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for hit in Self.blockingCallsInAsyncFunctions(in: text) {
                offenders.append("\(url.lastPathComponent) — \(hit)")
            }
        }
        // The premise floor, P43b's lesson: a sweep that scanned nothing
        // "passes".
        #expect(scanned > 100, "only \(scanned) ScarfCore sources scanned")
        #expect(offenders.isEmpty, "\(offenders)")
    }

    // MARK: - The async form behaves like the synchronous one

    @Test("the async reap returns the same verdict and the same bytes")
    func asyncFormMatchesTheSynchronousOne() async throws {
        func child(_ script: String) -> (Process, Pipe, Pipe) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            let err = Pipe()
            let out = Pipe()
            p.standardError = err
            p.standardOutput = out
            return (p, err, out)
        }
        // Past the 64 KB buffer, so only a concurrent drain can finish it.
        let script = "head -c 200000 /dev/zero | tr '\\000' 'x' 1>&2; exit 4"

        let (syncProc, syncErr, syncOut) = child(script)
        try syncProc.run()
        let syncResult = syncProc.waitDraining(timeout: 20, pipes: [syncErr, syncOut])
        try? syncErr.fileHandleForWriting.close()
        try? syncOut.fileHandleForWriting.close()

        let (asyncProc, asyncErr, asyncOut) = child(script)
        try asyncProc.run()
        let asyncResult = await asyncProc.waitDrainingAsync(timeout: 20, pipes: [asyncErr, asyncOut])
        try? asyncErr.fileHandleForWriting.close()
        try? asyncOut.fileHandleForWriting.close()

        #expect(syncResult.exited)
        #expect(asyncResult.exited == syncResult.exited)
        #expect(asyncResult.data == syncResult.data)
        #expect(asyncProc.terminationStatus == syncProc.terminationStatus)
        #expect(asyncProc.terminationStatus == 4)
    }

    @Test("the async reap gives up inside its budget, like the synchronous one")
    func asyncFormIsBounded() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec sleep 120"]
        let err = Pipe()
        p.standardError = err
        try p.run()

        let (exited, _) = await p.waitDrainingAsync(timeout: 0.5, pipes: [err])
        try? err.fileHandleForWriting.close()
        #expect(!exited, "a child that sleeps 120 s cannot exit inside 0.5 s")
    }

    // MARK: - `collect(grace:)` is a latch, not a check-then-set

    /// Two callers arriving together must get the SAME answer.
    ///
    /// Deterministic by construction rather than by luck: EOF is three seconds
    /// out, one caller's grace expires at one second and the other's at six.
    /// Under the old two-scope check-then-set both callers found the latch
    /// empty, both waited, and they returned different snapshots — empty for
    /// the short one, the full payload for the long one — with the late answer
    /// overwriting the early one. Holding the gate across the wait makes the
    /// loser of the race return the winner's answer, whichever one wins. The
    /// only timing assumption is that two threads released from one semaphore
    /// start within a second of each other.
    @Test("two concurrent collects return the same data")
    func collectIsIdempotentUnderConcurrency() throws {
        let pipe = Pipe()
        let drain = Process.startDraining(pipes: [pipe])
        let writer = pipe.fileHandleForWriting

        // EOF at ~3 s, on a thread of its own.
        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 3)
            try? writer.write(contentsOf: Data("P43C-PAYLOAD\n".utf8))
            try? writer.close()
        }

        let gate = DispatchSemaphore(value: 0)
        let results = OSAllocatedUnfairLock(initialState: [TimeInterval: [Data]]())
        let group = DispatchGroup()
        for grace in [1.0, 6.0] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                gate.wait()
                let data = drain.collect(grace: grace)
                results.withLock { $0[grace] = data }
                group.leave()
            }
        }
        gate.signal(); gate.signal()
        group.wait()

        let snapshot = results.withLock { $0 }
        let short = try #require(snapshot[1.0])
        let long = try #require(snapshot[6.0])
        #expect(short == long, Comment(rawValue:
            "collect is documented as idempotent but answered twice: "
            + "\(short.first?.count ?? -1) bytes vs \(long.first?.count ?? -1)"))
        // And the latch holds afterwards.
        #expect(drain.collect(grace: 6) == short)
    }
}
#endif
