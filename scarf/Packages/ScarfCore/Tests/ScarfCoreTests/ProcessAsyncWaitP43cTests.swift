#if !os(iOS)
import Foundation
import os
import Testing
@testable import ScarfCore

/// Round-4 P43c: the three NAMED synchronous reap spellings must not be
/// reachable from an `async` function, and `ProcessPipeDrain.collect` must be
/// a latch rather than a check-then-set.
///
/// **Scope** (narrowed in P46, widened in P48). This suite matches
/// ``blockingSpellings`` — `waitUntilExit(timeout:`, `.waitDraining(`,
/// `waitUntilExit()` — reached from `async` code three ways: called directly
/// in an `async` function body; called inside a `Task.detached { … }` or
/// `Task { … }` closure, which is the same cooperative pool and so the same
/// hazard under a different label; and called by a SYNCHRONOUS helper
/// declared in the same file that an `async` function in that file calls —
/// one level of indirection, which is where `LocalTransport.runProcess` and
/// `SSHTransport.runLocal` hid until round-5 P48 retired their unbounded
/// arms.
///
/// It still does not follow a call ACROSS files, and it is still syntactic.
/// What it buys is that the three shapes a phase has actually shipped are
/// each red on sight.
///
/// **Two roots** since P48: `Sources/ScarfCore` and the Mac app target
/// `scarf/scarf`, whose five sites were `t-12d04477`.
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
        var findings = declarationHits(in: source)
        findings.append(contentsOf: detachedClosureHits(in: source))
        findings.append(contentsOf: indirectHits(in: source))
        return findings
    }

    /// A blocking spelling inside a `Task.detached { … }` or `Task { … }`
    /// closure.
    ///
    /// `Task.detached` does not move a block off the cooperative pool — it IS
    /// the cooperative pool (round-4 P43c). The declaration walk cannot see
    /// this at all when the enclosing `func` is synchronous, which is exactly
    /// how all five app-target sites in `t-12d04477` stayed invisible: each
    /// sat in a `Task.detached` closure inside an ordinary `func`.
    static func detachedClosureHits(in source: String) -> [String] {
        let text = Array(stripped(source))
        var findings: [String] = []
        var i = 0
        while i + 4 < text.count {
            guard text[i] == "T",
                  String(text[i..<min(i + 4, text.count)]) == "Task",
                  (i == 0 || !(text[i - 1].isLetter || text[i - 1].isNumber || text[i - 1] == "_"))
            else { i += 1; continue }
            // Read forward to the `{` that opens the closure, allowing
            // `.detached`, a `(priority:)` argument list, and whitespace.
            var j = i + 4
            var parens = 0
            var bodyStart: Int?
            var sawOnlyAllowed = true
            while j < text.count {
                let c = text[j]
                if c == "(" { parens += 1; j += 1; continue }
                if c == ")" { parens -= 1; j += 1; continue }
                if c == "{", parens == 0 { bodyStart = j; break }
                if parens == 0, !(c.isWhitespace || c == "." || c.isLetter || c.isNumber || c == "_" || c == ":") {
                    sawOnlyAllowed = false
                    break
                }
                j += 1
            }
            guard sawOnlyAllowed, let start = bodyStart else { i += 4; continue }
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
            for spelling in blockingSpellings where body.contains(spelling) {
                findings.append("Task closure: \(spelling)")
            }
            i = start + 1
        }
        return findings
    }

    /// One level of indirection: an `async` function in this file calls a
    /// SYNCHRONOUS function declared in the same file whose body blocks.
    ///
    /// This is the shape P46 narrowed the suite's claim over and filed as
    /// `t-10eb7c17` item 0 — `LocalTransport.runProcess` and
    /// `SSHTransport.runLocal`, both synchronous, both blocking, both called
    /// from `async` code. One level, same file: following further would need
    /// a real call graph, and the two shapes that actually shipped are both
    /// reachable at this depth.
    static func indirectHits(in source: String) -> [String] {
        let decls = declarations(in: source)
        // Synchronous declarations whose own body blocks.
        var blockingSync: [String: String] = [:]
        for decl in decls where !decl.isAsync {
            for spelling in blockingSpellings where decl.body.contains(spelling) {
                blockingSync[decl.name] = spelling
            }
        }
        guard !blockingSync.isEmpty else { return [] }
        var findings: [String] = []
        for decl in decls where decl.isAsync {
            for (callee, spelling) in blockingSync where decl.body.contains(callee + "(") {
                findings.append("\(decl.name) -> \(callee): \(spelling)")
            }
        }
        return findings
    }

    /// One parsed function declaration.
    struct Declaration {
        let name: String
        let isAsync: Bool
        let body: String
    }

    /// Every `func` declaration in `source`, with its body.
    static func declarations(in source: String) -> [Declaration] {
        let text = Array(stripped(source))
        var out: [Declaration] = []
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
            let name = String(signature
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(while: { $0 != "(" && $0 != "<" }))
            let isAsync = signature.contains(" async ") || signature.contains(" async\n")
                || signature.contains(" async-> ") || signature.contains("async ->")
            out.append(Declaration(name: name, isAsync: isAsync, body: body))
            i = start + 1
        }
        return out
    }

    /// The original P43c walk: a blocking spelling directly in an `async`
    /// function's body.
    static func declarationHits(in source: String) -> [String] {
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

        // P48's two added shapes — hits.
        #expect(!Self.blockingCallsInAsyncFunctions(in: """
            func ordinary() {
                Task.detached {
                    _ = proc.waitUntilExit(timeout: 20)
                }
            }
            """).isEmpty, "a Task.detached closure is the same cooperative pool")
        #expect(!Self.blockingCallsInAsyncFunctions(in: """
            func ordinary() {
                Task {
                    _ = proc.waitDraining(timeout: 5, pipes: [a])
                }
            }
            """).isEmpty, "a Task closure is the same cooperative pool")
        #expect(!Self.blockingCallsInAsyncFunctions(in: """
            func helper() throws -> Int {
                _ = proc.waitUntilExit(timeout: 5)
                return 1
            }
            func caller() async throws -> Int {
                return try helper()
            }
            """).isEmpty, "one level of synchronous indirection is still the caller's thread")

        // P48's two added shapes — near-misses.
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            func ordinary() {
                Task.detached {
                    _ = await proc.waitDrainingAsync(timeout: 5, pipes: [a])
                }
            }
            """).isEmpty, "the async form inside a Task closure is correct")
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            func helper() throws -> Int { return 1 }
            func caller() async throws -> Int { return try helper() }
            """).isEmpty, "a synchronous helper that does not block is not a hit")
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            func helper() throws -> Int {
                _ = proc.waitUntilExit(timeout: 5)
                return 1
            }
            func other() throws -> Int { return try helper() }
            """).isEmpty, "a blocking helper called only from synchronous code is fine")
        #expect(Self.blockingCallsInAsyncFunctions(in: """
            let task = Task.detached { await work() }
            func unrelated() { _ = proc.waitUntilExit(timeout: 5) }
            """).isEmpty, "a blocking call OUTSIDE the closure is not a closure hit")

        // The stripper does not eat code.
        let kept = Self.stripped("let u = \"https://x/y\" // note\nlet n = 1\n")
        #expect(kept.contains("let n = 1"))
        #expect(!kept.contains("note"))
    }

    // MARK: - The sweep

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    static var scarfCoreSources: URL {
        repoRoot.appendingPathComponent("scarf/Packages/ScarfCore/Sources/ScarfCore")
    }

    /// Three roots since round-6 P53. The app target came in at P48, because
    /// `t-12d04477`'s five sites lived there and P43c had scoped itself to
    /// the package — a sweep that stops at its own module's edge blesses the
    /// other half of the same codebase by omission. The iOS runtime package
    /// is the same omission one module over: it was in none of the three C10
    /// sweeps, and `CitadelServerTransport`'s unbounded `semaphore.wait()`
    /// sat there through five rounds.
    static var sweepRoots: [URL] {
        [
            scarfCoreSources,
            repoRoot.appendingPathComponent("scarf/scarf"),
            repoRoot.appendingPathComponent("scarf/Packages/ScarfIOS/Sources/ScarfIOS"),
        ]
    }

    /// The one file where the synchronous form is called on purpose: it
    /// IMPLEMENTS the helpers, and `waitDrainingAsync` is a wrapper around
    /// exactly this.
    static let implementationFile = "ProcessTimeout.swift"

    /// EMPTY, and the P37 rule says an empty allowlist has to be replaced by
    /// a calibration test rather than trusted — which is what
    /// ``matcherIsCalibrated`` is, over all six shapes.
    ///
    /// The one app-target reap that stays synchronous on purpose,
    /// `HermesFileService.runShellProbe`, needs no entry: its only caller is
    /// an `enrichedShellEnv` `static let` initializer, not a `func`, so no
    /// rule here matches it. That is the honest answer rather than a comfortable
    /// one — the sweep does not read property initializers, and saying so is
    /// better than an allowance implying it does (round-5 P48, t-12d04477).
    static let allowances: [String: String] = [:]

    @Test("both sweep roots exist")
    func sweepRootsExist() {
        for root in Self.sweepRoots {
            #expect(
                FileManager.default.fileExists(atPath: root.path),
                "sweep root moved: \(root.path)")
        }
    }

    /// The title says what the sweep PROVES. Since P48 that is three shapes,
    /// over two roots: a blocking spelling called directly in an `async`
    /// body, one inside a `Task { … }` / `Task.detached { … }` closure, and
    /// one reached through a synchronous helper declared in the same file.
    /// It still does not follow a call across files.
    @Test("no async code in ScarfCore or the Mac app reaps a child synchronously")
    func noSynchronousReapInAsyncCode() throws {
        var scannedPerRoot: [String: Int] = [:]
        var offenders: [String] = []
        var allowanceHits: Set<String> = []

        for root in Self.sweepRoots {
            #expect(FileManager.default.fileExists(atPath: root.path), "the sweep root moved")
            let walker = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                "could not enumerate \(root.path)")
            var scanned = 0
            for case let url as URL in walker where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                if name == Self.implementationFile { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                let hits = Self.blockingCallsInAsyncFunctions(in: text)
                guard !hits.isEmpty else { continue }
                if Self.allowances[name] != nil {
                    allowanceHits.insert(name)
                    continue
                }
                for hit in hits { offenders.append("\(name) — \(hit)") }
            }
            scannedPerRoot[root.lastPathComponent] = scanned
        }

        // The premise floor, P43b's lesson, per root: a sweep that scanned
        // nothing "passes". Recalibrated honestly in P48 — these are the
        // real counts at the time of writing, halved so ordinary deletion
        // cannot make the floor the thing that fails.
        let core = scannedPerRoot["ScarfCore"] ?? 0
        let app = scannedPerRoot["scarf"] ?? 0
        let ios = scannedPerRoot["ScarfIOS"] ?? 0
        #expect(core > 100, "only \(core) ScarfCore sources scanned")
        #expect(app > 200, "only \(app) app-target sources scanned")
        // ScarfIOS is a 14-file package: its floor is its own size halved,
        // not the app target's (round-6 P53).
        #expect(ios > 5, "only \(ios) ScarfIOS sources scanned")
        #expect(offenders.isEmpty, "\(offenders)")
        // Every allowance must still be a live debt, or it is a stale entry
        // hiding the next violation (the P37 rule).
        #expect(
            allowanceHits == Set(Self.allowances.keys),
            "stale allowance(s): \(Set(Self.allowances.keys).subtracting(allowanceHits))")
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
