import Testing
import Foundation

/// Release blocker 2 — the OffPool sweep's domain is `Task.detached` bodies,
/// so a blocking seam in a plain `async func` (or an `async` actor method) is
/// invisible to it BY CONSTRUCTION. Eleven such sites shipped in the
/// Backup / Restore / Logs surfaces: `transport.runProcess(…)` is a
/// synchronous 30–60 s SSH round trip, and calling it from an `async` body
/// parks a cooperative-pool thread — charter C10, and on the Backup sheet's
/// first paint it was a per-project loop of them.
///
/// This sweep's region is every `async` function BODY, brace-matched, and its
/// needle is a BARE `runProcess(`. The cure is `await …asyncRunProcess(…)`,
/// so both discriminators matter: `containsNeedle` keeps `asyncRunProcess(`
/// from matching `runProcess(` on the left boundary, and `isAwaitedCall`
/// distinguishes the async seam from the blocking one. Work already inside
/// `OffPool.run { }` is exempt — that IS the opt-out.
///
/// Helpers are shared with the P52 sweep rather than re-implemented: a
/// re-implementation cannot fail when the original drifts.
///
/// **What this sweep can and cannot see, measured.** Run against the code as
/// it stood before the fix, it reported 8 of the 10 converted sites. The two
/// it missed — `HermesLogService.readLastLines` and
/// `RemoteBackupService.estimateBytes` — were SYNCHRONOUS functions then, so
/// they were outside the region by definition; the fix made each `async` AND
/// awaited its call in the same edit. That is the honest scope: this guards
/// against a blocking call being ADDED to (or an `await` being dropped from)
/// an async body, not against a whole blocking helper being carved back out
/// into a sync function. The `asyncRunProcess(` premise check per file is
/// what fails in that second case.
@Suite("Blocking seams stay out of async function bodies (release blockers)")
struct AsyncFunctionBlockingSeamTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    /// The four files the round-7 audit named, by REPO-RELATIVE PATH — never
    /// by basename (the P49b lesson). A file that disappears fails the test
    /// rather than silently emptying the sweep.
    private static let sweptFiles = [
        "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteBackupService.swift",
        "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/RemoteRestoreService.swift",
        "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesLogService.swift",
        "scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ServerContext.swift",
    ]

    /// The needle, and the cure it must not be confused with.
    private static let needle = "runProcess("

    // MARK: - Region matcher

    /// The 0-based line indices covered by the body of every `async`
    /// function in `lines`, brace-matched from the `{` that opens the body.
    ///
    /// A declaration's signature may span lines, so the scan accumulates from
    /// `func ` until the body's opening `{` and asks whether `async` appeared
    /// in what it accumulated. `async let`, `async {` and a trailing
    /// `async` closure parameter are not function declarations and never
    /// start a region, because the region only ever starts at a `func `.
    static func asyncFunctionLineRanges(in lines: [String]) -> Set<Int> {
        var region: Set<Int> = []
        var i = 0
        while i < lines.count {
            let code = OffPoolDisciplineP52Tests.stripComment(lines[i])
            guard code.range(of: "func ") != nil else { i += 1; continue }
            // Accumulate the signature until the body's `{` (or `;`/EOF).
            var signature = ""
            var j = i
            var bodyStart: (line: Int, offset: String.Index)?
            while j < lines.count, j < i + 40 {
                let text = OffPoolDisciplineP52Tests.stripComment(lines[j])
                if let brace = text.firstIndex(of: "{"), j > i || brace > (code.range(of: "func ")?.lowerBound ?? text.startIndex) {
                    signature += text[text.startIndex..<brace]
                    bodyStart = (j, text.index(after: brace))
                    break
                }
                signature += text + " "
                j += 1
            }
            guard let start = bodyStart, signature.range(of: "async") != nil else {
                i += 1
                continue
            }
            // Brace-match the body.
            var depth = 1
            var line = start.line
            var scanFrom = start.offset
            while line < lines.count {
                let text = OffPoolDisciplineP52Tests.stripComment(lines[line])
                let from = (line == start.line) ? scanFrom : text.startIndex
                var idx = from
                while idx < text.endIndex {
                    if text[idx] == "{" { depth += 1 }
                    if text[idx] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    idx = text.index(after: idx)
                }
                region.insert(line)
                if depth == 0 { break }
                line += 1
                scanFrom = text.startIndex
            }
            i = max(line, start.line) + 1
        }
        return region
    }

    /// Bare (un-awaited, un-pooled) `runProcess(` hits inside an `async`
    /// function body, as `line number: text`.
    static func blockingSeams(in source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        let region = asyncFunctionLineRanges(in: lines)
        let pooled = OffPoolDisciplineP52Tests.offPoolLineRanges(in: lines)
        var hits: [String] = []
        for (i, raw) in lines.enumerated() where region.contains(i) && !pooled.contains(i) {
            let code = OffPoolDisciplineP52Tests.stripComment(raw)
            guard OffPoolDisciplineP52Tests.containsNeedle(needle, in: code) else { continue }
            guard !OffPoolDisciplineP52Tests.isAwaitedCall(needle, in: code) else { continue }
            hits.append("\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
        }
        return hits
    }

    // MARK: - Calibration

    /// The matcher is calibrated against a PLANTED needle — including every
    /// near-miss that makes the rule load-bearing: the cure spelling, a
    /// pooled call, and a call in a SYNCHRONOUS function (which this sweep
    /// deliberately does not own; `nonisolated` sync helpers are the
    /// transport's own layer).
    @Test("the matcher finds a planted needle and none of its near-misses")
    func matcherIsCalibrated() throws {
        let planted = """
            actor Probe {
                func blocking() async throws {
                    let r = try transport.runProcess(executable: "/bin/sh", args: [])
                    _ = r
                }
                func cured() async throws {
                    let r = try await transport.asyncRunProcess(executable: "/bin/sh", args: [])
                    _ = r
                }
                func alreadyAwaited() async throws {
                    let r = try await transport.runProcess(executable: "/bin/sh", args: [])
                    _ = r
                }
                func pooled() async throws {
                    let r = try await OffPool.run {
                        try transport.runProcess(executable: "/bin/sh", args: [])
                    }
                    _ = r
                }
                nonisolated func synchronous() throws {
                    _ = try transport.runProcess(executable: "/bin/sh", args: [])
                }
                func multiLineSignature(
                    a: Int,
                    b: Int
                ) async -> Int {
                    _ = try? transport.runProcess(executable: "/bin/sh", args: [])
                    return a + b
                }
            }
            """
        let hits = Self.blockingSeams(in: planted)
        #expect(hits.count == 2, "expected the two planted needles, got: \(hits)")
        #expect(hits.contains { $0.hasSuffix(#"let r = try transport.runProcess(executable: "/bin/sh", args: [])"#) },
                "the single-line async body's needle was missed: \(hits)")
        #expect(hits.contains { $0.contains("try? transport.runProcess") },
                "a needle under a MULTI-LINE async signature was missed: \(hits)")
    }

    // MARK: - The sweep

    @Test("Backup / Restore / Logs async bodies carry no blocking runProcess")
    func namedFilesHaveNoBlockingSeams() throws {
        var offenders: [String] = []
        for relative in Self.sweptFiles {
            let url = Self.repoRoot.appendingPathComponent(relative)
            let source = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "the sweep's target is gone — update `sweptFiles`: \(relative)"
            )
            // Premise: the file really is the one the audit named.
            #expect(source.contains("asyncRunProcess("),
                    "\(relative) no longer uses the async process seam at all — is this still the right file?")
            for hit in Self.blockingSeams(in: source) {
                offenders.append("\(relative):\(hit)")
            }
        }
        #expect(offenders.isEmpty, """
            A synchronous `transport.runProcess(…)` sits inside an `async` function body. \
            It parks a cooperative-pool thread for the whole SSH round trip (charter C10). \
            Use `try await transport.asyncRunProcess(…)` with the same timeout:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
