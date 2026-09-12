import Testing
import Foundation
@testable import scarf

/// P38 items 21/22/25 — three source sweeps.
///
/// Two of them (the test-host stability pair) have no runtime signal by
/// construction: the failure mode they guard against is a TRAP, and a trap in
/// one Swift Testing test kills the whole `scarfTests` host, taking every
/// other suite's result with it. There is nothing to observe afterwards — so
/// the alarm has to be the SHAPE being present in the source. That is also
/// how these were watched failing: the offending lines were still in the tree
/// when the sweeps were first run, and both reported them.
@Suite("P38 — source sweeps")
struct HermesP38SourceSweepTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    private static let testRoots = [
        "scarf/scarfTests",
        "scarf/Scarf iOSTests",
        "scarf/Packages/ScarfCore/Tests/ScarfCoreTests",
    ]

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

    /// These sweeps match on source text, so they would match themselves.
    private static let ownFileName = URL(fileURLWithPath: #filePath).lastPathComponent

    private static func isComment(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: .whitespaces)
        return bare.hasPrefix("//") || bare.hasPrefix("///") || bare.hasPrefix("*")
    }

    // MARK: - 22: no `try! #require` in a test

    /// `try! #require(x)` traps when `x` is nil — which is the ONE case the
    /// expression exists to report. `@Test func … throws` plus `try #require`
    /// fails that one test instead of the host.
    ///
    /// Scoped to `#require` deliberately. A `try!` on a literal fixture
    /// (`try! JSONDecoder().decode(…, from: Data(json.utf8))` over a string
    /// written three lines above) traps only if the test file itself is
    /// malformed, which every other assertion in the file would also catch;
    /// `try! #require` traps on exactly the condition under test.
    @Test func noTestForceTriesARequire() {
        var offenders: [String] = []
        for root in Self.testRoots {
            for url in Self.swiftFiles(under: root) {
                guard url.lastPathComponent != Self.ownFileName else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in src.components(separatedBy: "\n").enumerated()
                where line.contains("try! #require") && !Self.isComment(line) {
                    offenders.append("\(url.lastPathComponent):\(i + 1) — "
                                     + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: """
            `try! #require` traps on failure and a trap takes the whole test \
            host down. Make the test `throws` and use `try #require`: \
            \(offenders.joined(separator: "; "))
            """))
    }

    // MARK: - 21: no subscript straight after a count expectation

    /// `#expect(xs.count == 1)` followed by `xs[0]` is the exact shape that
    /// crashed the host three times in round 3: the expectation RECORDS a
    /// failure and execution continues into an out-of-bounds index. Either
    /// `guard xs.count == 1 else { Issue.record(…); return }` or
    /// `try #require(xs.first)`.
    /// **Repo-wide since round-5 P48 (decision 7).** Every `.swift` file
    /// under ``phaseSuiteRoots`` — the app target, the iOS target and the
    /// ScarfCore package — is swept, with no scope predicate at all.
    ///
    /// The scoping is worth remembering as a sequence of honest compromises
    /// rather than as a mistake. P38 hand-listed 17 phase suites; P45
    /// replaced the list with a phase-NAME pattern, which finds new phase
    /// suites by construction but reads nothing a phase writes in an
    /// ordinarily-named file; P46 added the branch's own touched files by
    /// PATH, which closed that and found seven more sites. Each step was
    /// bounded by the same fact: a repo-wide run reported ~90 pre-existing
    /// sites, and a sweep that fails on day one is a sweep somebody disables.
    /// P48 is the day the 90 were fixed, so the scope is gone and future
    /// phases append nothing. `t-f43f0af5` closed with it.

    /// Premise floor. A sweep that reads nothing "passes": 484 test files
    /// matched when P48 made this repo-wide, and the floor is well under that
    /// so ordinary deletion cannot make the floor the thing that fails, and
    /// well over zero so a broken enumeration cannot hide.
    static let testFileFloor = 300

    /// The roots the phase sweep walks — the same three the `try! #require`
    /// sweep above uses, spelled separately because ScarfCore's root is the
    /// whole `Tests` directory (it holds two test targets), not just
    /// `ScarfCoreTests`.
    private static let phaseSuiteRoots = [
        "scarf/scarfTests",
        "scarf/Scarf iOSTests",
        "scarf/Packages/ScarfCore/Tests",
    ]

    @Test func noSubscriptFollowsACountExpectation() {
        var offenders: [String] = []
        var scanned: Set<String> = []
        for root in Self.phaseSuiteRoots {
            for url in Self.swiftFiles(under: root) {
                guard url.lastPathComponent != Self.ownFileName else { continue }
                scanned.insert(url.lastPathComponent)
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = src.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    guard !Self.isComment(line),
                          line.contains("#expect("), line.contains(".count")
                    else { continue }
                    // The receiver whose count was asserted: the token right
                    // before `.count`.
                    guard let dot = line.range(of: ".count") else { continue }
                    let receiver = String(line[line.startIndex..<dot.lowerBound])
                        .split(whereSeparator: { " (!=<>&|,".contains($0) })
                        .last.map(String.init) ?? ""
                    guard !receiver.isEmpty else { continue }
                    // Look at the next few statements for a bare subscript on
                    // that same receiver.
                    for j in (i + 1)..<min(i + 5, lines.count) {
                        let next = lines[j]
                        guard !Self.isComment(next) else { continue }
                        // A `guard`/`#require` in between is the correct fix
                        // and ends the window.
                        if next.contains("guard ") || next.contains("#require(") { break }
                        guard let open = next.range(of: receiver + "[") else { continue }
                        // A string-keyed lookup (`findings["File"]`) is a
                        // dictionary read: it returns nil, it does not trap.
                        if next[open.upperBound...].hasPrefix("\"") { break }
                        // So is an OPTIONAL-CHAINED one (`map[1]?.first`):
                        // `Dictionary.subscript` returns an Optional, and the
                        // `?` right after the closing bracket is the proof —
                        // an Array subscript is non-optional and cannot be
                        // chained that way. P46's note listed this shape as a
                        // known false positive; round-5 P48 tightens the
                        // matcher rather than exempting the file it lives in.
                        if let close = next.range(of: "]", range: open.upperBound..<next.endIndex),
                           next[close.upperBound...].hasPrefix("?") { break }
                        offenders.append("\(url.lastPathComponent):\(j + 1) — "
                                         + next.trimmingCharacters(in: .whitespaces))
                        break
                    }
                }
            }
        }
        #expect(scanned.count >= Self.testFileFloor, Comment(rawValue:
            "the sweep read only \(scanned.count) test files "
            + "(floor \(Self.testFileFloor)) — it cannot have covered the roots"))
        #expect(offenders.isEmpty, Comment(rawValue: """
            A subscript follows a count `#expect` with no guard between them. \
            `#expect` records and CONTINUES, so a wrong count runs straight \
            into an out-of-bounds trap and kills the test host: \
            \(offenders.joined(separator: "; "))
            """))
    }

    // MARK: - 22b: `try? #require` swallows the requirement

    /// `try? #require(x)` is `try! #require(x)`'s quiet twin: the `#require`
    /// failure is DISCARDED and the test continues with `nil`, so what the
    /// reader sees is an optional-chained `== true` failing somewhere below
    /// with no statement of what was actually missing — or, worse, an
    /// assertion that vacuously holds. The point of `#require` is to stop.
    @Test func noTestOptionalTriesARequire() {
        var offenders: [String] = []
        for root in Self.phaseSuiteRoots {
            for url in Self.swiftFiles(under: root) {
                guard url.lastPathComponent != Self.ownFileName else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in src.components(separatedBy: "\n").enumerated()
                where line.contains("try? #require") && !Self.isComment(line) {
                    offenders.append("\(url.lastPathComponent):\(i + 1) — "
                                     + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: """
            `try? #require` discards the requirement and continues with nil. \
            Make the test `throws` and use `try #require`: \
            \(offenders.joined(separator: "; "))
            """))
    }

    // MARK: - 22c: no long fixed sleep in a test

    /// P45's lesson: "a test that naps and then asserts is asserting about
    /// the clock". A fixed sleep of half a second or more is either a race
    /// waiting to be lost on a loaded machine or half a second of wall clock
    /// added to every serial run — usually both. Poll an observable instead.
    ///
    /// Allowed sites, each with a written reason, because each sleep is not a
    /// wait for an observable: it is the FIXTURE, a deliberate "nothing
    /// happened" window (which by construction has nothing to poll for), or a
    /// watchdog that a healthy run cancels before it ever elapses.
    ///
    /// Round-5 P48 widened this rule from the branch-scoped files to the whole
    /// test tree, so the list below is now the repo-wide answer. Everything
    /// that COULD be polled was converted rather than allowed — the FSEvents
    /// naps in `HermesFileWatcherAtomicReplaceTests`, the mtime gap in
    /// `KeychainEnvMirrorTests`, and `GwF4OutcomeMessageChannelTests`'s one
    /// auto-clear that actually fires.
    static let allowedFixedSleeps: [String: String] = [
        "ProcessAsyncWaitP43cTests.swift:603":
            "the 3 s is the FIXTURE — EOF deliberately lands between the two "
            + "graces (1 s and 6 s) so the latch race is decided by construction, "
            + "not by luck; it runs on a background queue, not in the test body",
        "MainActorSpawnDisciplineP22Tests.swift:251":
            "the assertion is that the cancelled load did NOT reach its third "
            + "probe, so there is no observable to poll for; the window is one "
            + "probe delay (0.3 s) times three",
        "PreReleaseFixupTests.swift:28":
            "the assertion is that a FAILURE did not auto-clear after the "
            + "success path's 3 s TTL — a non-event, so there is nothing to "
            + "poll; the wait must outlast the real timer to mean anything",
        "GwF4OutcomeMessageChannelTests.swift:64":
            "same non-event: a failure must still be on screen after the "
            + "success TTL has elapsed. The sibling that asserts a success DOES "
            + "clear polls for it instead",
        "GwF4OutcomeMessageChannelTests.swift:94":
            "same non-event, with the extra condition that an EARLIER success's "
            + "pending timer must not wipe the refusal that landed after it",
        "ProcessACPChannelTests.swift:80":
            "a WATCHDOG, not a wait: the sleep runs in a task the test cancels "
            + "as soon as the echo arrives, so a healthy run never spends any "
            + "of it — it exists to turn a hang into a failure",
        "ProcessACPChannelTests.swift:136":
            "the same watchdog on the stdout/stderr interleaving test",
    ]

    /// The seconds a sleep on this line lasts, or `nil` if the line is not a
    /// fixed sleep the sweep can read.
    ///
    /// P46b: the capture was `([0-9][0-9_]*)` — INTEGER digits only — so
    /// `Thread.sleep(forTimeInterval: 0.9)` read as `0` and `.seconds(0.5)`
    /// as `0`, and both fell under the half-second floor the rule exists to
    /// enforce. The two spellings that happened to be in scope were both
    /// whole-number nanosecond counts, which is why nobody noticed. The
    /// fraction is part of the number now, and the unit is read from the
    /// argument LABEL as well as the duration spelling: `forTimeInterval:`
    /// is `Thread.sleep`'s seconds label and has no `.seconds` token on the
    /// line to fall through to.
    static func fixedSleepSeconds(in line: String) -> [Double] {
        let pattern = #"(?:Task|Thread)\.sleep\([^)]*?([0-9][0-9_]*(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        var out: [Double] = []
        for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        where m.numberOfRanges > 1 {
            let digits = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "_", with: "")
            guard let raw = Double(digits) else { continue }
            if line.contains("nanoseconds") { out.append(raw / 1_000_000_000) }
            else if line.contains("microseconds") { out.append(raw / 1_000_000) }
            else if line.contains("milliseconds") { out.append(raw / 1_000) }
            else { out.append(raw) }   // `.seconds(…)` and `forTimeInterval:`
        }
        return out
    }

    @Test func noTestSleepsAFixedHalfSecondOrMore() {
        var offenders: [String] = []
        var allowancesSeen: Set<String> = []
        for root in Self.phaseSuiteRoots {
            for url in Self.swiftFiles(under: root) {
                guard url.lastPathComponent != Self.ownFileName else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in src.components(separatedBy: "\n").enumerated() {
                    guard !Self.isComment(line) else { continue }
                    for seconds in Self.fixedSleepSeconds(in: line) {
                        guard seconds >= 0.5 else { continue }
                        let site = "\(url.lastPathComponent):\(i + 1)"
                        if Self.allowedFixedSleeps[site] != nil {
                            allowancesSeen.insert(site)
                            continue
                        }
                        offenders.append("\(site) — " + line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: """
            A test sleeps a fixed half second or more. Poll the observable the \
            work produces instead, or add the site to `allowedFixedSleeps` with \
            a reason: \(offenders.joined(separator: "; "))
            """))
        // The allowances are calibrated, not decorative: a stale one means the
        // site moved and the sweep is no longer reading it.
        let stale = Set(Self.allowedFixedSleeps.keys).subtracting(allowancesSeen)
        #expect(stale.isEmpty, Comment(rawValue:
            "allowed sleep sites no longer match anything — they have moved: "
            + stale.sorted().joined(separator: ", ")))
    }

    // MARK: - 25: every platform form reads `.env` under the shared guard

    /// P37 finding 5's guard lives in `PlatformSetupHelpers.loadSnapshot`:
    /// `guard snapshot.envFailure == nil else { return }` sits immediately
    /// before `apply(snapshot)`, so a refused `.env` read never blanks a live
    /// credential on screen. That guard protects a form only if the form's
    /// `snapshot.env` read happens INSIDE the `loadSnapshot` closure. A VM
    /// that called `PlatformSetupHelpers.loadForm` directly, or read
    /// `snapshot.env` from anywhere else, would silently opt out.
    @Test func everyPlatformFormReadsEnvUnderTheSharedGuard() throws {
        let dir = Self.repoRoot
            .appendingPathComponent("scarf/scarf/Features/Platforms/ViewModels/PlatformSetup")
        let forms = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix("SetupViewModel.swift") }
            .sorted()
        #expect(forms.count >= 14, "the sweep stopped finding the forms: \(forms)")

        var offenders: [String] = []
        var readEnv = 0
        for name in forms {
            let src = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            // Nobody but the helper may call `loadForm` — that is the entry
            // point BELOW the guard.
            if src.contains("PlatformSetupHelpers.loadForm(") {
                offenders.append("\(name): calls loadForm directly, bypassing the envFailure guard")
            }
            let lines = src.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("snapshot.env") {
                guard !Self.isComment(line) else { continue }
                // `snapshot.envFailure` is the guard itself, not a read.
                guard !line.contains("snapshot.envFailure") else { continue }
                readEnv += 1
                // Walk up to the enclosing closure opener.
                var inLoadSnapshot = false
                var j = i - 1
                while j >= 0, i - j < 40 {
                    if lines[j].contains("loadSnapshot") { inLoadSnapshot = true; break }
                    if lines[j].contains("    func ") { break }
                    j -= 1
                }
                if !inLoadSnapshot {
                    offenders.append("\(name):\(i + 1) reads `snapshot.env` outside the"
                                     + " `loadSnapshot` closure")
                }
            }
        }
        #expect(readEnv > 0, "the `snapshot.env` matcher stopped matching")
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "; ")))
    }
}

// MARK: - P46b finding 4: the fixed-sleep matcher is calibrated

/// The rule's number-matcher captured INTEGER digits only, so
/// `Thread.sleep(forTimeInterval: 0.9)` measured as 0 seconds and
/// `.seconds(0.5)` as 0 — both under the half-second floor the rule exists to
/// enforce. Calibrated here rather than only over the tree, because the tree
/// happened to contain no fractional spelling: a matcher with no calibration
/// test is a matcher that can stop matching in silence.
/// This suite lives in the sweep's own file ON PURPOSE: its calibration
/// cases are sleep spellings written as string literals, and any other file
/// in scope would have the sweep read them as real sleeps. `ownFileName` is
/// already excluded, so the cases sit where they cannot trip the rule they
/// calibrate.
@Suite("P46b · the fixed-sleep matcher is calibrated")
struct FixedSleepMatcherP46bTests {

    @Test func everyDurationSpellingIsConverted() {
        let cases: [(String, Double)] = [
            ("try await Task.sleep(nanoseconds: 500_000_000)", 0.5),
            ("try await Task.sleep(for: .milliseconds(900))", 0.9),
            ("try await Task.sleep(for: .seconds(0.5))", 0.5),
            ("Thread.sleep(forTimeInterval: 0.9)", 0.9),
            ("Thread.sleep(forTimeInterval: 3)", 3),
            ("try await Task.sleep(for: .microseconds(750_000))", 0.75),
        ]
        for (line, expected) in cases {
            let found = HermesP38SourceSweepTests.fixedSleepSeconds(in: line)
            #expect(found.first == expected,
                    Comment(rawValue: "`\(line)` measured \(found), expected [\(expected)]"))
        }
    }

    /// The fraction is the fix: these four all read as `0` before it, i.e.
    /// the rule silently passed them.
    @Test func aFractionalSleepIsNoLongerReadAsZero() {
        for line in ["Thread.sleep(forTimeInterval: 0.9)",
                     "try await Task.sleep(for: .seconds(0.5))",
                     "try await Task.sleep(for: .seconds(1.5))"] {
            let found = HermesP38SourceSweepTests.fixedSleepSeconds(in: line)
            #expect(found.first ?? 0 >= 0.5,
                    Comment(rawValue: "`\(line)` measured \(found) — under the floor"))
        }
    }

    /// …and a genuinely short sleep still passes, or the rule would fire on
    /// every poll interval in the suite.
    @Test func aShortSleepIsStillShort() {
        #expect(HermesP38SourceSweepTests.fixedSleepSeconds(
            in: "try await Task.sleep(for: .milliseconds(50))").first == 0.05)
        #expect(HermesP38SourceSweepTests.fixedSleepSeconds(
            in: "try await Task.sleep(nanoseconds: 10_000_000)").first == 0.01)
        #expect(HermesP38SourceSweepTests.fixedSleepSeconds(in: "await settle()").isEmpty)
    }
}
