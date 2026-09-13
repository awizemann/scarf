import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Round-5 P52 — blocking work belongs on a thread of its own, not on the
/// cooperative pool.
///
/// P22 asked "is this off the MAIN actor?" and `Task.detached` answers yes.
/// It is the wrong question for BLOCKING work: a detached task runs on the
/// Swift concurrency cooperative pool, one thread per core and unable to
/// grow, so a detached `enrichedEnvironment()` parks a pool thread through
/// two `zsh` probes (5 s + 3 s) and a detached `loadState()` parks one
/// through a full SSH `readFile`. P48 wrote the rule down — "`Task.detached`
/// is not an escape from the cooperative pool, and it is the shape a phase
/// reaches for when it wants one" — and P51 then reached for it three more
/// times, which is why the shape is now pinned here rather than only stated.
///
/// The cure is ``OffPool/run(_:)``: the `withCheckedContinuation` +
/// `Thread.detachNewThread` shape `Process.waitUntilExitAsync` already was,
/// hoisted for the non-`Process` callers.
@Suite("Blocking work stays off the cooperative pool (P52)")
struct OffPoolDisciplineP52Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func swiftFiles(under relative: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    /// This file names both needles in its own prose, so it must exempt
    /// itself — by PATH, never by basename (the P49b lesson: a basename
    /// exemption silently covers any future same-named file elsewhere).
    private static let ownPath = URL(fileURLWithPath: #filePath)
        .standardizedFileURL.path

    /// Four roots since round-6 P53. `ScarfIOS` is the iOS RUNTIME package
    /// (Citadel SSH, the transports); it was in none of the three C10 sweeps'
    /// roots, which is how `CitadelServerTransport.runSync`'s unbounded
    /// `semaphore.wait()` stayed invisible for five rounds.
    private static let roots = [
        "scarf/scarf",
        "scarf/Scarf iOS",
        "scarf/Packages/ScarfCore/Sources",
        "scarf/Packages/ScarfIOS/Sources",
    ]

    /// Per-root floors (P60 finding 3, P38's table shape).
    ///
    /// The sweep's premise check was a shared `> 0` per root, which is not a
    /// floor: `scarf/Packages/ScarfIOS/Sources` is 14 files and `scarf/Scarf
    /// iOS` 50, so a root that half-stopped enumerating — or one whose walk
    /// found a single file — still "passed". Each floor is set well under
    /// the root's real population so ordinary deletion cannot make the floor
    /// the thing that fails, and well over zero so a broken enumeration
    /// cannot hide.
    ///
    /// Populations at P60: 299 / 50 / 217 / 14.
    private static let perRootFloor: [String: Int] = [
        "scarf/scarf": 200,
        "scarf/Scarf iOS": 30,
        "scarf/Packages/ScarfCore/Sources": 150,
        "scarf/Packages/ScarfIOS/Sources": 8,
    ]

    /// P60 finding 4, the assertion P22 has and this sweep did not
    /// (`MainActorSpawnDisciplineP22Tests.swift:433`): MEMBERSHIP, not just
    /// existence. A root can be DELETED from ``roots`` and its floor above
    /// goes with it, which is exactly how `ScarfIOS` was absent from all
    /// three C10 sweeps for five rounds without a single test going red.
    @Test("every root the sweep walks is present and exists")
    func sweepRootsAreThePinnedRoster() {
        #expect(Set(Self.roots) == Set(Self.perRootFloor.keys),
                "a root has no floor, or a floor has no root — the two lists have drifted")
        #expect(Self.roots.contains("scarf/Packages/ScarfIOS/Sources"),
                "the iOS runtime package is no longer swept")
        #expect(Self.roots.contains("scarf/Scarf iOS"),
                "the iOS app target is no longer swept")
        for relative in Self.roots {
            var isDir: ObjCBool = false
            let path = Self.repoRoot.appendingPathComponent(relative).path
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            #expect(exists && isDir.boolValue,
                    Comment(rawValue: "sweep root \(relative) is missing"))
        }
    }

    /// The calls whose bodies BLOCK their thread for a user-visible span, and
    /// which a phase has already put inside a `Task.detached` at least once.
    ///
    /// Deliberately a short, evidenced list rather than a general "blocking
    /// call" heuristic: each entry is a site round-5 actually got wrong.
    /// `enrichedEnvironment()` reads a `static let` whose initialiser is two
    /// `zsh` probes at 5 s + 3 s (`HermesFileService.swift:2566-2583`, probes
    /// at `:2575` and `:2580`) behind a `swift_once`; `loadState()` is a
    /// `readFile` of `auth.json` through the context's transport, i.e. an SSH
    /// round trip on a remote server.
    static let blockingNeedles = [
        "enrichedEnvironment()",
        "loadState()",
        // Round-6 P58. The first two are the shape the four streaming spawns
        // had: a blocking `read(2)` on the pool for the life of the stream.
        // `waitUntilExit(` is the bounded-but-still-blocking process wait —
        // the async form is `waitUntilExitAsync(`/`waitDrainingAsync(`, which
        // the paren keeps out. `runHermesCLI(` and `runProcess(` are the two
        // seams that ARE a process wait one frame down, and P54 put six of
        // them inside `Task.detached` in this round alone.
        "availableData",
        "readDataToEndOfFile",
        "waitUntilExit(",
        "runHermesCLI(",
        "runProcess(",
        // Round-6 P58b. `Process.run()` is a fork/exec that resolves PATH and
        // can block for a user-visible span — `HermesProxyService` moved its
        // spawn off the pool for exactly that reason and stated it, while
        // three siblings (`HealthViewModel`, `MCPLoginController`,
        // `OAuthFlowController`) kept `Task.detached { try proc.run() }`. One
        // rationale, four call sites: either the needle finds them or the
        // rationale was wrong. The bare `run()` spelling is what a `Process`
        // call looks like; `OffPool.run { … }` takes a closure and never
        // spells the empty parens, so the cure is not a hit.
        "run()",
        // Round-6 P59. The cross-phase review's finding: the sweep asked
        // about `runHermesCLI(` and `readFile(`'s caller but not about the
        // two seams the ViewModels actually use.
        // `ServerContext.runHermes` / `runHermesSplit`
        // (`ServerContext+Mac.swift:21-24`, `:33-36`) are one-line wrappers
        // around `runHermesCLI` / `runHermesCLISplit`, so a site that spells
        // the wrapper blocks exactly as long as one that spells the wrapped
        // call and the sweep could not see 20 of them. `readText(` /
        // `readFile(` are the transport reads — an SFTP round trip on a
        // remote server — and `KanbanToolsetDetector` rode one on the pool
        // for four rounds.
        "runHermes(",
        "runHermesSplit(",
        "readText(",
        "readFile(",
        // P60. The round-7 review's finding, and the same shape twice more:
        // `runHermesCLI(` cannot match `runHermesCLISplit(` — the needle's
        // trailing `(` is the boundary, which is exactly what keeps the two
        // baselines from double-counting — so NINE split sites in detached
        // bodies were invisible to a sweep that names only the non-split
        // call.
        // `runHermesSync(` is `CuratorService`'s own nonisolated static
        // wrapper (`CuratorService.swift:742`), one frame above
        // `transport.runProcess`. `capabilitiesSync(`
        // (`HermesVersionCache.swift:208`) is the synchronous capability
        // probe: on a cold cache it SPAWNS `hermes --version` and waits.
        // The generalisable rule, stated once here because P58, P59 and P60
        // each learned it separately: **a needle must be accompanied by
        // every one-call wrapper of it in the tree.** When you add a needle,
        // grep the tree for functions whose whole body is that call — a
        // `Split` sibling, a `…Sync` façade, a `ServerContext` convenience —
        // and add each of them too, because a wrapper blocks for exactly as
        // long as the thing it wraps and is invisible to the wrapped call's
        // spelling.
        "runHermesCLISplit(",
        "runHermesSync(",
        "capabilitiesSync(",
    ]

    /// Needles whose ASYNC twin shares their spelling, so an occurrence that
    /// is directly `await`ed is the cure and not the defect.
    ///
    /// `SkillsViewModel` has its OWN `static func runHermes(executable:…)
    /// async`, which is `transport.asyncRunProcess` underneath (round-6
    /// decision 11's seam, `SkillsViewModel.swift:1132-1155`) — ten call
    /// sites of it sit inside `Task.detached` bodies and NONE of them parks
    /// a thread. `ServerContext.runHermes` is `nonisolated` and synchronous,
    /// so `await` can never precede it. That asymmetry is the whole rule:
    /// awaited ⇒ the async seam, bare ⇒ the blocking one. It is narrower
    /// than dropping the needle and narrower than exempting the file, and it
    /// keeps a future blocking `ctx.runHermes(` in `SkillsViewModel` visible.
    static let awaitedIsTheCure: Set<String> = ["runHermes(", "runHermesSplit("]

    /// Is the occurrence of `needle` in `line` directly preceded by `await`?
    static func isAwaitedCall(_ needle: String, in line: String) -> Bool {
        var search = line[line.startIndex...]
        var sawBare = false
        while let range = search.range(of: needle) {
            // Walk back over the receiver chain (`Self.`, `ctx.`, …) to the
            // token in front of the call expression.
            var idx = range.lowerBound
            while idx > line.startIndex {
                let before = line.index(before: idx)
                let c = line[before]
                guard c.isLetter || c.isNumber || c == "_" || c == "." else { break }
                idx = before
            }
            let prefix = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces)
            if prefix.hasSuffix("await") { search = line[range.upperBound...] } else { sawBare = true; break }
        }
        return !sawBare
    }

    /// Does `line` contain `needle` as its own identifier?
    ///
    /// A plain `contains` makes `asyncRunProcess(` — the iOS ASYNC seam, the
    /// cure rather than the defect — a hit for `runProcess(`, and would make
    /// any future `fooLoadState()` one too. The boundary is on the LEFT only:
    /// every needle already ends in `(` or `)`, except the two `FileHandle`
    /// properties, which are whole words in practice.
    static func containsNeedle(_ needle: String, in line: String) -> Bool {
        var search = line[line.startIndex...]
        while let range = search.range(of: needle) {
            if range.lowerBound == line.startIndex {
                return true
            }
            let before = line[line.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            search = line[range.upperBound...]
        }
        return false
    }

    /// The sites the WIDENED needles (round-6 P58) found and P58 did not
    /// fix, keyed `basename:needle` with the NUMBER of hits in that file.
    ///
    /// This is a baseline, not an exemption: every entry is a real charter
    /// C10 violation and every one of them belongs to `t-406d56d6`, the task
    /// that owns "the remaining blocking `Task.detached` sites". P58 widened
    /// the needles from two to seven, which took the tree from 2 reported
    /// sites to 42; it fixed the 20 on the paths its task named — the six P54
    /// `runHermesCLI` sites, their siblings in the same four files, and the
    /// iOS `runProcess` call sites that round-6 decision 11 made `async` —
    /// and wrote the rest down here rather than either leaving the needles
    /// narrow or dumping 22 fresh failures on the next phase.
    ///
    /// Round-6 P59 widened them again, from eight to twelve
    /// (`runHermes(`, `runHermesSplit(`, `readText(`, `readFile(`), fixed
    /// the ten sites its finding named — nine `ctx.runHermes` ViewModel
    /// bodies and `KanbanToolsetDetector` — and re-baselined the rest. The
    /// baseline was 38 hits across 26 keys after P59; it was 29 before that,
    /// and it grows because the sweep can now SEE more, not because the tree
    /// got worse: converting `BotConversationViewModel` took three
    /// `runProcess(` hits off it in the same pass.
    ///
    /// Round-7 P60 widened them a fourth time, from twelve to fifteen
    /// (`runHermesCLISplit(`, `runHermesSync(`, `capabilitiesSync(`),
    /// converted the three sites that were the plain
    /// `await Task.detached { … }.value` shape and baselined eleven more:
    /// **49 hits across 32 keys**.
    ///
    /// It is COUNTED so it cannot rot into a licence: one more
    /// `runHermesCLI(` in `CronViewModel` is a new offender even though the
    /// file is listed, and fixing one is a FAILURE until the number comes
    /// down with it.
    ///
    /// The two `ProfilesViewModel` entries are worth naming, because they are
    /// the shape that does NOT convert mechanically: both are inside
    /// `RemoteProfileExport.run`'s `runCLI:` / `streamFile:` closures, which
    /// are synchronous function values — `await` cannot go there until the
    /// parameter's type changes.
    static let pendingOffPoolSites: [String: Int] = [
        "GitBranchService.swift:runProcess(": 1,
        "KanbanService.swift:runProcess(": 1,
        "SkillPrereqService.swift:runProcess(": 1,
        "HermesFileService.swift:runHermesCLI(": 1,
        "HermesProxyService.swift:runHermesCLI(": 1,
        "OAuthKeepaliveCronService.swift:runHermesCLI(": 2,
        "CronViewModel.swift:runHermesCLI(": 4,
        "HealthView.swift:runHermesCLI(": 1,
        "MCPLoginController.swift:runProcess(": 2,
        "MCPServersViewModel.swift:runHermesCLI(": 1,
        "PluginsViewModel.swift:runHermesCLI(": 1,
        "ProfilesViewModel.swift:runHermesCLI(": 1,
        "ProfilesViewModel.swift:runProcess(": 1,
        "LogTailWidgetView.swift:runProcess(": 1,
        // Round-6 P58b's `run()` needle. P58b converted the four sites its
        // finding named (`HermesProxyService` was already off; `HealthViewModel`,
        // `MCPLoginController` and `OAuthFlowController` joined it); these
        // seven are the rest of the tree and belong to `t-406d56d6`. All are
        // `Task.detached` spawn bodies in the transports and the connection
        // probe, where the `run()` sits alongside the pipe wiring and the
        // drain it owns — a mechanical `OffPool.run` wrap around the whole
        // body would move the continuation plumbing too, so they are a
        // deliberate follow-up rather than a one-line change.
        "SSHTransport.swift:run()": 2,
        "SSHScriptRunner.swift:run()": 2,
        "LocalTransport.swift:run()": 2,
        "TestConnectionProbe.swift:run()": 1,
        // Round-6 P59's `readText(` / `readFile(` needles. P59 converted the
        // one site its finding named — `KanbanToolsetDetector`, whose whole
        // detached body WAS the `readText` — and the nine `ctx.runHermes`
        // ViewModel sites; these eleven are the rest and belong to
        // `t-406d56d6`. None is the one-line shape: every one is a
        // multi-statement detached body that reads a file ALONGSIDE other
        // work, and three of them (`CuratorViewModel`, `LogTailWidgetView`,
        // `ProjectCockpitViewModel`) `await` inside that body, which
        // `OffPool.run`'s synchronous closure cannot take. Splitting them is
        // a refactor of the load, not a wrap, so it is a follow-up and not a
        // line this phase could honestly claim to have tested.
        "CredentialPoolsViewModel.swift:readText(": 1,
        "CuratorViewModel.swift:readText(": 1,
        "KanbanSummaryWidgetView.swift:readFile(": 1,
        "LogTailWidgetView.swift:readFile(": 1,
        "PersonalitiesViewModel.swift:readText(": 2,
        "ProjectCockpitViewModel.swift:readText(": 2,
        "SettingsViewModel.swift:readText(": 3,
        "SkillsViewModel.swift:readText(": 1,
        // P60's three needles (`runHermesCLISplit(`, `runHermesSync(`,
        // `capabilitiesSync(`). P60 converted the three sites that were the
        // plain `await Task.detached { … }.value` shape — `CuratorService`'s
        // `status()` and its single `runHermes` seam, and
        // `IOSSettingsViewModel`'s managed-install probe — and baselined
        // these eleven, which belong to `t-406d56d6`.
        //
        // Reasons, one per key. None is the plain shape: every one is a
        // multi-statement `Task.detached` body that ends in
        // `await MainActor.run { … }`, so `OffPool.run`'s SYNCHRONOUS
        // closure cannot take the body whole, and the conversion is a split
        // of the load (blocking half off-pool, publish half on the main
        // actor) rather than a wrap.
        //
        //   SettingsViewModel:runHermesCLISplit — `approvals suggest --json`
        //     and its `--apply <n>` sibling; the apply body also calls
        //     `svc.loadConfig()` between the CLI and the hop.
        //   SettingsViewModel:capabilitiesSync — inside the four-call heavy
        //     load, alongside `loadConfig`/`loadGatewayState`/`readText`.
        //   PluginsViewModel:capabilitiesSync + :runHermesCLISplit — one
        //     detached body that probes capabilities, then branches into
        //     either a CLI call or a directory walk, then runs
        //     `plugins compat`.
        //   CronViewModel:runHermesCLISplit — `cron runs`, `cron incidents`,
        //     `cron doctor`, each parsing before its main-actor hop.
        //   PeersViewModel:runHermesCLISplit — `peer dm` (600 s), `peer run`
        //     (120 s) and the run-status poll; the DM's timeout is the CLI's
        //     own `DM_TIMEOUT_S` and must survive any conversion.
        "SettingsViewModel.swift:runHermesCLISplit(": 2,
        "SettingsViewModel.swift:capabilitiesSync(": 1,
        "PluginsViewModel.swift:runHermesCLISplit(": 1,
        "PluginsViewModel.swift:capabilitiesSync(": 1,
        "CronViewModel.swift:runHermesCLISplit(": 3,
        "PeersViewModel.swift:runHermesCLISplit(": 3,
    ]

    /// A `Task.detached` closure the sweep may keep, keyed
    /// `basename: needle`, each with a written reason.
    ///
    /// Calibrated like every other allowance in this tree: an entry that
    /// stops matching is a stale allowance hiding the next violation, and
    /// ``blockingCallsDoNotRideTaskDetached`` fails on one.
    static let allowances: [String: String] = [
        "scarfApp.swift:enrichedEnvironment()": """
            The launch warm-up, and the ONE site whose whole purpose is to \
            park a thread until the `swift_once` is populated. It runs once, \
            at `.utility`, before any window exists, and every later caller \
            reads the memoised value — so the pool thread it holds is the \
            price of never holding a UI one. Converting it would be correct \
            and pointless; saying why is the honest answer.
            """,
    ]

    // MARK: - The matcher

    /// `source` with every `//` comment's TEXT replaced by spaces, keeping
    /// the byte and line count identical so offsets and line numbers are
    /// unaffected. Block comments are not handled: the tree uses `///` and
    /// `//` throughout, and a half-supported stripper is worse than a stated
    /// limit.
    static func blankComments(in source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            let code = stripComment(line)
            if code.count == line.count { return line }
            return code + String(repeating: " ", count: line.count - code.count)
        }.joined(separator: "\n")
    }

    /// Every `Task.detached { … }` closure body in `source`, brace-matched.
    ///
    /// The round-6 review's finding: the sweep matched per LINE, so it only
    /// ever caught `Task.detached { svc.loadState() }` written on ONE line.
    /// All four real sites in the tree spell the needle several lines below
    /// the `Task.detached`, and every one of them passed. This is the walker
    /// ``ProcessAsyncWaitP43cTests/detachedClosureHits(in:)`` already uses,
    /// reimplemented here because the two suites live in different targets.
    ///
    /// - Returns: `(startLine, body)` per closure, 1-based.
    static func detachedClosures(in source: String) -> [(line: Int, body: String)] {
        // Comments are blanked FIRST, in place, so line numbers survive.
        // Round-6 P58: `PipeReader.swift`'s doc comment spells the defect it
        // replaced — `Task.detached { while true { handle.availableData } }` —
        // and the walker brace-matched from inside the PROSE, then reported
        // the needle on the same comment line. The per-line filter below
        // could not see it, because the body starts mid-line and so carries
        // no `///` prefix. A sweep that reports the documentation of the fix
        // as the bug is worse than no sweep: it teaches the next phase to
        // stop reading the output.
        let chars = Array(blankComments(in: source))
        // Line number for any index, computed once.
        var lineAt = [Int](repeating: 1, count: chars.count + 1)
        var line = 1
        for (i, c) in chars.enumerated() {
            lineAt[i] = line
            if c == "\n" { line += 1 }
        }
        lineAt[chars.count] = line

        var out: [(line: Int, body: String)] = []
        var i = 0
        while i + 13 < chars.count {
            guard chars[i] == "T",
                  String(chars[i..<(i + 13)]) == "Task.detached",
                  (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_"))
            else { i += 1; continue }
            // Read forward to the `{` that opens the closure, allowing a
            // `(priority:)` argument list and whitespace.
            var j = i + 13
            var parens = 0
            var bodyStart: Int?
            var ok = true
            while j < chars.count {
                let c = chars[j]
                if c == "(" { parens += 1; j += 1; continue }
                if c == ")" { parens -= 1; j += 1; continue }
                if c == "{", parens == 0 { bodyStart = j; break }
                if parens == 0, !(c.isWhitespace || c == "." || c.isLetter
                                  || c.isNumber || c == "_" || c == ":") {
                    ok = false
                    break
                }
                j += 1
            }
            guard ok, let start = bodyStart else { i += 13; continue }
            var depth = 0
            var k = start
            var body = ""
            while k < chars.count {
                if chars[k] == "{" { depth += 1 }
                if chars[k] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(chars[k])
                k += 1
            }
            out.append((line: lineAt[i], body: body))
            i = start + 1
        }
        return out
    }

    /// The needles a closure body actually parks on the pool.
    ///
    /// Code inside an `OffPool.run { … }` is not a hit: the blocking call is
    /// already on its own thread and the enclosing `Task.detached` is a pure
    /// orchestrator (`HealthViewModel`'s seven-way `async let` batch is
    /// exactly this, and the round-6 report named it as a live site on the
    /// strength of the brace match alone). The exemption is REGIONAL rather
    /// than per body, so a body that wraps one of two blocking calls still
    /// reports the other.
    ///
    /// Round-6 P53b: the exemption used to be per LINE, which failed the
    /// same way the sweep it guards used to — the real form is
    /// `await OffPool.run {` on one line and the blocking call on the next,
    /// and that line was reported. It brace-matches the region now. A
    /// trailing `// OffPool.run` comment used to exempt a line outright;
    /// comments are stripped first.
    static func pooledBlockingNeedles(in body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        let exempt = offPoolLineRanges(in: lines)
        var hits: [String] = []
        for (i, raw) in lines.enumerated() {
            guard !exempt.contains(i) else { continue }
            let bare = stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard !bare.isEmpty, !bare.hasPrefix("*") else { continue }
            for needle in blockingNeedles where containsNeedle(needle, in: bare) {
                if awaitedIsTheCure.contains(needle), isAwaitedCall(needle, in: bare) { continue }
                hits.append(needle)
            }
        }
        return hits
    }

    /// A line with its trailing `//` comment removed. `://` is left alone so
    /// a URL literal does not swallow the rest of the line.
    static func stripComment(_ line: String) -> String {
        var out = ""
        var prev: Character?
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            let next = line.index(after: i)
            if c == "/", next < line.endIndex, line[next] == "/", prev != ":" { break }
            out.append(c)
            prev = c
            i = next
        }
        return out
    }

    /// The 0-based line indices covered by an `OffPool.run { … }` region,
    /// brace-matched from the `{` that follows each occurrence.
    static func offPoolLineRanges(in lines: [String]) -> Set<Int> {
        var exempt: Set<Int> = []
        var depth = 0
        for (i, raw) in lines.enumerated() {
            let code = stripComment(raw)
            var scan = code[code.startIndex...]
            if depth == 0, let hit = code.range(of: "OffPool.run") {
                // The call's own line is exempt from the `{` onwards; the
                // simplest honest rule is to exempt the whole line, since a
                // blocking call before `OffPool.run` on the SAME line is
                // already inside some other expression.
                exempt.insert(i)
                scan = code[hit.upperBound...]
            } else if depth > 0 {
                exempt.insert(i)
            } else {
                continue
            }
            for c in scan {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth <= 0 { depth = 0; break }
                }
            }
        }
        return exempt
    }

    @Test("the matcher sees a needle several lines inside the closure")
    func matcherIsCalibrated() throws {
        let planted = """
            func probe() {
                Task.detached(priority: .utility) {
                    let proc = Process()
                    if true {
                        let env = HermesFileService.enrichedEnvironment()
                        _ = env
                    }
                }
                Task.detached {
                    async let a = OffPool.run { svc.loadState() }
                    _ = await a
                }
                Task { let x = svc.loadState(); _ = x }
            }
            """
        let closures = Self.detachedClosures(in: planted)
        #expect(closures.count == 2, "the walker found \(closures.count) detached closures, expected 2")
        let first = try #require(closures.first)
        #expect(first.body.contains("enrichedEnvironment()"),
                "the brace match stopped before the needle — this is the per-line bug the walk replaces")
        #expect(Self.pooledBlockingNeedles(in: first.body) == ["enrichedEnvironment()"])
        let second = try #require(closures.dropFirst().first)
        #expect(Self.pooledBlockingNeedles(in: second.body).isEmpty,
                "a needle already inside `OffPool.run` is not a pool hit")
    }

    /// The five needles P58 added, planted, plus the two near-misses that
    /// make the boundary rule load-bearing.
    @Test("the widened needles match the real shapes and not their cures")
    func widenedNeedlesAreCalibrated() throws {
        let planted = """
            func probe() {
                Task.detached {
                    let chunk = handle.availableData
                    let all = handle.readDataToEndOfFile()
                    _ = proc.waitUntilExit(timeout: 5)
                    _ = fileService.runHermesCLI(args: [])
                    _ = try transport.runProcess(executable: "x", args: [])
                    try proc.run()
                    _ = (chunk, all)
                }
            }
            """
        let closure = try #require(Self.detachedClosures(in: planted).first)
        let hits = Set(Self.pooledBlockingNeedles(in: closure.body))
        #expect(hits == Set(["availableData", "readDataToEndOfFile",
                             "waitUntilExit(", "runHermesCLI(", "runProcess(",
                             "run()"]),
                "the widened needle set missed \(Set(Self.blockingNeedles).subtracting(hits))")

        // The near-misses. `asyncRunProcess(` IS the cure decision 11 added,
        // and `waitUntilExitAsync(`/`waitDrainingAsync(` are the async waits
        // — reporting any of them would make the sweep tell a phase to undo
        // its own fix.
        let cures = """
                _ = try await transport.asyncRunProcess(executable: "x", args: [])
                _ = await proc.waitUntilExitAsync(timeout: 5)
                _ = await proc.waitDrainingAsync(timeout: 5, drain: d)
                _ = await OffPool.run { try? proc.run() }
            """
        #expect(Self.pooledBlockingNeedles(in: cures).isEmpty, """
            The sweep reports the ASYNC seams as blocking: \
            \(Self.pooledBlockingNeedles(in: cures)). A `contains` match makes \
            `asyncRunProcess(` a `runProcess(` hit — the boundary rule in \
            `containsNeedle` is what stops it.
            """)
        #expect(Self.containsNeedle("runProcess(", in: "try t.runProcess(x)"))
        #expect(!Self.containsNeedle("runProcess(", in: "try await t.asyncRunProcess(x)"))
        #expect(Self.containsNeedle("run()", in: "try proc.run()"))
        #expect(!Self.containsNeedle("run()", in: "await OffPool.run { work() }"))
    }

    /// The four needles P59 added, planted, plus the near-miss that makes
    /// the `await` rule load-bearing.
    ///
    /// `ctx.runHermes(…)` is `ServerContext+Mac.swift:21-24` — one line
    /// around `HermesFileService.runHermesCLI`, i.e. a process spawn or an
    /// SSH exec channel — and twenty of them rode `Task.detached` while the
    /// sweep asked only about the wrapped call. `SkillsViewModel`'s
    /// same-named `static func runHermes(executable:…) async` is
    /// `asyncRunProcess` underneath and must NOT be reported, or the sweep
    /// tells the next phase to undo round-6 decision 11.
    @Test("the P59 needles match the blocking seams and not their async twins")
    func contextSeamNeedlesAreCalibrated() throws {
        let planted = """
            func probe() {
                Task.detached {
                    _ = ctx.runHermes(["status"], timeout: 60)
                    _ = ctx.runHermesSplit(["doctor"], timeout: 60)
                    let yaml = ctx.readText(ctx.paths.configYAML)
                    let data = transport.readFile(path)
                    _ = (yaml, data)
                }
            }
            """
        let closure = try #require(Self.detachedClosures(in: planted).first)
        let hits = Set(Self.pooledBlockingNeedles(in: closure.body))
        #expect(hits == Set(["runHermes(", "runHermesSplit(", "readText(", "readFile("]),
                "the P59 needle set missed \(Set(["runHermes(", "runHermesSplit(", "readText(", "readFile("]).subtracting(hits))")

        // The near-misses. `Self.runHermes(` awaited is `SkillsViewModel`'s
        // async seam; `runHermesCLI(` must stay its own needle rather than
        // being swallowed by the shorter one.
        let cures = """
                let result = await Self.runHermes(
                    executable: bin, args: args, transport: xport, timeout: 30)
                let split = await Self.runHermesSplit(
                    executable: bin, args: args, transport: xport, timeout: 30)
                _ = (result, split)
            """
        #expect(Self.pooledBlockingNeedles(in: cures).isEmpty, Comment(rawValue: """
            The sweep reports `SkillsViewModel`'s ASYNC `runHermes` seam as \
            blocking: \(Self.pooledBlockingNeedles(in: cures)). Ten call \
            sites of it sit in `Task.detached` bodies and none parks a \
            thread — reporting them tells the next phase to undo decision 11.
            """))
        #expect(Self.isAwaitedCall("runHermes(", in: "let r = await Self.runHermes("))
        #expect(!Self.isAwaitedCall("runHermes(", in: "let r = ctx.runHermes([\"status\"])"))
        // A body with BOTH shapes still reports the bare one.
        #expect(Self.pooledBlockingNeedles(in: """
                let a = await Self.runHermes(executable: bin, args: [], transport: x, timeout: 5)
                let b = ctx.runHermes(["status"], timeout: 60)
                _ = (a, b)
            """) == ["runHermes("])
        // And `runHermesCLI(` is not a `runHermes(` hit, or the baseline
        // keys would double-count every CLI site.
        #expect(!Self.containsNeedle("runHermes(", in: "svc.runHermesCLI(args: [])"))
    }

    /// The three needles P60 added, planted, plus the near-miss that is the
    /// whole reason they were invisible: `runHermesCLI(` CANNOT match
    /// `runHermesCLISplit(`, because the needle's trailing `(` is a literal
    /// character and `Split` sits between the name and the paren. That is
    /// the property the two baselines rely on to avoid double-counting, and
    /// it is also what hid eleven split sites for three rounds — so it is
    /// asserted in both directions here rather than assumed.
    @Test("the P60 needles match the split and sync wrappers, and the CLI needle does not")
    func wrapperNeedlesAreCalibrated() throws {
        let planted = """
            func probe() {
                Task.detached {
                    let split = svc.runHermesCLISplit(args: ["plugins", "compat"], timeout: 45)
                    let sync = Self.runHermesSync(context: ctx, args: ["curator", "status"], timeout: 30)
                    let caps = HermesVersionCache.shared.capabilitiesSync(for: ctx)
                    _ = (split, sync, caps)
                }
            }
            """
        let closure = try #require(Self.detachedClosures(in: planted).first)
        let hits = Set(Self.pooledBlockingNeedles(in: closure.body))
        #expect(hits == Set(["runHermesCLISplit(", "runHermesSync(", "capabilitiesSync("]),
                "the P60 needle set missed \(Set(["runHermesCLISplit(", "runHermesSync(", "capabilitiesSync("]).subtracting(hits))")

        // The boundary, both ways. This is the finding: a sweep that names
        // `runHermesCLI(` sees NOTHING of `runHermesCLISplit(`.
        #expect(!Self.containsNeedle("runHermesCLI(", in: "svc.runHermesCLISplit(args: [])"), """
            `runHermesCLI(` matched `runHermesCLISplit(` — if that ever \
            becomes true the two baseline keys double-count every split site.
            """)
        #expect(Self.containsNeedle("runHermesCLISplit(", in: "svc.runHermesCLISplit(args: [])"))
        // And the left boundary still holds for the two new wrappers.
        #expect(Self.containsNeedle("runHermesSync(", in: "Self.runHermesSync(context: c)"))
        #expect(!Self.containsNeedle("runHermesSync(", in: "let x = asyncRunHermesSync(c)"))
        #expect(Self.containsNeedle("capabilitiesSync(", in: "cache.capabilitiesSync(for: ctx)"))
        #expect(!Self.containsNeedle("capabilitiesSync(", in: "x.hermesCapabilitiesSync(for: ctx)"))
        // The cure: wrapped in `OffPool.run`, none of the three is a hit.
        #expect(Self.pooledBlockingNeedles(in: """
                let caps = await OffPool.run {
                    HermesVersionCache.shared.capabilitiesSync(for: ctx)
                }
                _ = caps
            """).isEmpty)
    }

    /// The baseline's own size, pinned (lesson 6: a number in a comment is a
    /// claim nobody executes). The doc above ``pendingOffPoolSites`` says 49
    /// hits across 32 keys; this is what re-measures it, so a phase that
    /// adds or clears an entry must restate the prose. The needle set's own
    /// size is pinned for the same reason. The vocabulary has been widened
    /// four times and the count is now 15: 2 (P52) → 7 (P58) → 8 (P58b's
    /// `run()`) → 12 (P59) → 15 (P60). Every widening restates it here, and
    /// this assertion is the only place the number is executed.
    @Test("the pending-site baseline is the size its documentation claims")
    func baselineSizeIsPinned() {
        #expect(Self.pendingOffPoolSites.count == 32)
        #expect(Self.pendingOffPoolSites.values.reduce(0, +) == 49)
        #expect(Self.blockingNeedles.count == 15)
        #expect(Set(Self.blockingNeedles).count == 15, "a needle is listed twice")
    }

    /// The walker must not read PROSE. `PipeReader.swift`'s doc comment
    /// spells the defect it replaced — `Task.detached { while true {
    /// handle.availableData } }` — and the pre-P58 walker brace-matched from
    /// inside that sentence and reported the needle. The per-line comment
    /// filter could not save it: the matched body starts mid-line, so it
    /// carries no `///`. A sweep whose first report is the documentation of
    /// the fix teaches the next phase to ignore its output.
    @Test("a `Task.detached` inside a comment is not a closure")
    func theWalkerSkipsComments() {
        let planted = """
            /// Why not `Task.detached { while true { handle.availableData } }`?
            /// Because it parks a pool thread.
            func real() {
                let x = 1
            }
            """
        #expect(Self.detachedClosures(in: planted).isEmpty, """
            The walker matched `Task.detached` inside a doc comment — it is \
            reading prose as code.
            """)
        // And it still sees the real one directly underneath a mention.
        let mixed = """
            // Task.detached is not an escape.
            func real() {
                Task.detached {
                    _ = handle.availableData
                }
            }
            """
        #expect(Self.detachedClosures(in: mixed).count == 1)
        // Blanking preserves the line count, or every reported line number
        // after a comment would be wrong.
        #expect(Self.blankComments(in: mixed).components(separatedBy: "\n").count
                == mixed.components(separatedBy: "\n").count)
    }

    /// The exemption's own two failure modes, planted (round-6 P53b).
    @Test("the pool exemption is a brace-matched region, and not a comment")
    func theExemptionIsCalibrated() throws {
        // 1. The real shape: `OffPool.run {` opens, the blocking call is on
        //    the NEXT line. A per-line exemption reported this.
        let wrapped = """
                let state = try await OffPool.run {
                    svc.loadState()
                }
                let after = HermesFileService.enrichedEnvironment()
            """
        #expect(!Self.pooledBlockingNeedles(in: wrapped).contains("loadState()"), """
            A blocking call wrapped across the `OffPool.run` line break is \
            reported as if it rode the pool — the exemption is per line again.
            """)
        // The call AFTER the region closes is still a hit, or the exemption
        // has swallowed the rest of the body.
        #expect(Self.pooledBlockingNeedles(in: wrapped).contains("enrichedEnvironment()"),
                "the region never closed — everything after `OffPool.run` is exempt")

        // 2. A trailing comment is not an exemption.
        let commented = """
                let state = svc.loadState() // OffPool.run
            """
        #expect(Self.pooledBlockingNeedles(in: commented) == ["loadState()"], """
            A trailing `// OffPool.run` comment exempts the line — the sweep \
            is defeated by a comment.
            """)

        // 3. Two calls, one wrapped: the other is still reported.
        let mixed = """
                async let a = OffPool.run { svc.loadState() }
                let env = HermesFileService.enrichedEnvironment()
            """
        #expect(Self.pooledBlockingNeedles(in: mixed) == ["enrichedEnvironment()"])
    }

    @Test("no blocking call is parked on the cooperative pool by `Task.detached`")
    func blockingCallsDoNotRideTaskDetached() {
        var offenders: [String] = []
        var scannedByRoot: [String: Int] = [:]
        var allowancesSeen: Set<String> = []
        var hitsByKey: [String: [String]] = [:]

        for root in Self.roots {
            for url in Self.swiftFiles(under: root) {
                guard url.standardizedFileURL.path != Self.ownPath else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scannedByRoot[root, default: 0] += 1
                for closure in Self.detachedClosures(in: src) {
                    for needle in Self.pooledBlockingNeedles(in: closure.body) {
                        let key = "\(url.lastPathComponent):\(needle)"
                        if Self.allowances[key] != nil {
                            allowancesSeen.insert(key)
                            continue
                        }
                        hitsByKey[key, default: []]
                            .append("\(url.lastPathComponent):\(closure.line) — \(needle)")
                    }
                }
            }
        }

        // A baselined file keeps exactly its recorded number of hits; any
        // EXTRA is a new offender and is reported with its line.
        for (key, hits) in hitsByKey {
            let baselined = Self.pendingOffPoolSites[key] ?? 0
            guard hits.count > baselined else { continue }
            offenders.append(contentsOf: hits.suffix(hits.count - baselined))
        }
        // And a baseline that over-counts is a fix nobody finished recording.
        let shrunk = Self.pendingOffPoolSites.compactMap { key, count -> String? in
            let actual = hitsByKey[key]?.count ?? 0
            return actual < count ? "\(key): baselined \(count), found \(actual)" : nil
        }
        #expect(shrunk.isEmpty, Comment(rawValue:
            "`pendingOffPoolSites` claims more hits than the tree has. Sites were fixed"
            + " (good) without taking them off the baseline, which leaves a licence for"
            + " someone to put them back: " + shrunk.sorted().joined(separator: "; ")))

        // Premise floor, per root (P60 finding 3). A shared `> 0` is not a
        // floor: a root that enumerated ONE file cleared it.
        for root in Self.roots {
            let floor = Self.perRootFloor[root] ?? 0
            #expect((scannedByRoot[root] ?? 0) >= floor, Comment(rawValue:
                "the sweep read \(scannedByRoot[root] ?? 0) Swift files under \(root),"
                + " below the floor of \(floor) — the walk is broken or the root moved"))
        }

        #expect(offenders.isEmpty, Comment(rawValue: """
            A blocking call sits inside a `Task.detached`. That is off the \
            MAIN actor but still on the cooperative pool — one thread per \
            core, unable to grow — so it parks a thread every other task in \
            the process is competing for (charter C10). Use \
            `OffPool.run { … }`, which gives the blocking work a thread of \
            its own: \(offenders.joined(separator: "; "))
            """))

        let stale = Set(Self.allowances.keys).subtracting(allowancesSeen)
        #expect(stale.isEmpty, Comment(rawValue:
            "allowed detached site(s) no longer match anything — they have moved: "
            + stale.sorted().joined(separator: ", ")))
    }

    /// The helper itself, pinned: if `OffPool.run` ever becomes a
    /// `Task.detached` wrapper, every call site above silently regresses and
    /// the sweep still passes. (Its BEHAVIOUR is tested in ScarfCore, where
    /// it lives — `OffPoolP52Tests`.)
    @Test("`OffPool.run` detaches a real thread, not a pool task")
    func offPoolUsesAThread() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "scarf/Packages/ScarfCore/Sources/ScarfCore/Models/OffPool.swift"),
            encoding: .utf8)
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
        #expect(code.contains("Thread.detachNewThread"))
        #expect(code.contains("withCheckedContinuation"))
        #expect(!code.contains("Task.detached"))
    }

    // MARK: - The `enrichedShellEnv` citation, pinned

    /// Three sites carried `HermesFileService.swift:2468-2484` for
    /// `enrichedShellEnv` — a range that is the `stopGateway` verdict
    /// docstring, copied comment-to-comment across P51. The real declaration
    /// is `:2566-2583`, with the probes at `:2575` (5 s) and `:2580` (3 s).
    ///
    /// A citation nobody can check rots silently, which is the P26 idea: make
    /// the check mechanical. This asserts that every comment in the tree
    /// citing a LINE RANGE in `HermesFileService.swift` for this environment
    /// probe actually brackets the line `runShellProbe(script:` is on today.
    /// When the file shifts, this goes red and the ranges get restated — that
    /// is the maintenance the test exists to force, not a flaw in it.
    @Test("every `enrichedShellEnv` citation brackets the real probe line")
    func enrichedShellEnvCitationsAreCurrent() throws {
        let servicePath = "scarf/scarf/Core/Services/HermesFileService.swift"
        let service = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(servicePath), encoding: .utf8)
        let serviceLines = service.components(separatedBy: "\n")
        let probeLine = try #require(
            serviceLines.firstIndex(where: { $0.contains("runShellProbe(script:") })
                .map { $0 + 1 },
            "no `runShellProbe(script:` call in \(servicePath) — the probe was renamed")

        // `HermesFileService.swift:<lo>-<hi>` in a comment that is talking
        // about the login-shell environment (the `zsh` probes), which is the
        // only citation family this pins.
        let pattern = try NSRegularExpression(
            pattern: #"HermesFileService\.swift:(\d+)-(\d+)"#)
        var offenders: [String] = []
        var checked = 0

        for root in Self.roots {
            for url in Self.swiftFiles(under: root) {
                guard url.standardizedFileURL.path != Self.ownPath else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = src.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    // Only the comment that is about the shell probes: the
                    // neighbourhood text ("zsh probes", "enrichedShellEnv")
                    // within a few lines either side.
                    let lo = max(0, i - 4), hi = min(lines.count - 1, i + 4)
                    let neighbourhood = lines[lo...hi].joined(separator: " ")
                    guard neighbourhood.contains("zsh` probes")
                        || neighbourhood.contains("enrichedShellEnv") else { continue }
                    let ns = line as NSString
                    guard let m = pattern.firstMatch(
                        in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                    checked += 1
                    let low = Int(ns.substring(with: m.range(at: 1))) ?? 0
                    let high = Int(ns.substring(with: m.range(at: 2))) ?? 0
                    if !(low...max(low, high)).contains(probeLine) {
                        offenders.append(
                            "\(url.lastPathComponent):\(i + 1) cites :\(low)-\(high), "
                            + "but `runShellProbe(script:` is at :\(probeLine)")
                    }
                }
            }
        }

        #expect(checked > 0,
                "no `enrichedShellEnv` citation was found — the matcher stopped matching")
        #expect(offenders.isEmpty, Comment(rawValue: """
            A comment cites a line range in HermesFileService.swift for the \
            login-shell probes that no longer contains them. Restate the \
            range (this is how `:2468-2484`, the `stopGateway` verdict doc, \
            ended up on three sites): \(offenders.joined(separator: "; "))
            """))
    }
}
