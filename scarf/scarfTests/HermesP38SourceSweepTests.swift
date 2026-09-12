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
    /// **Scoped to the phase suites**, not the whole tree: every file whose
    /// name carries a phase number (`…P39Tests.swift`, `HermesP44bTests.swift`,
    /// `…P0Tests.swift`) under any of ``phaseSuiteRoots`` — the app target,
    /// the iOS target, and the ScarfCore package.
    /// A repo-wide run reports ~100 pre-existing sites in non-phase files,
    /// and fixing those is a separate mechanical pass (filed as `t-f43f0af5`)
    /// — a sweep that fails on day one is a sweep somebody disables. What it
    /// does buy: every suite the audit branches wrote is held to the rule,
    /// and a new phase suite that reintroduces the shape fails here.
    ///
    /// Round 4 replaced a hand-kept allowlist with this pattern. The
    /// allowlist had stopped at P39 — P40–P44 and every ScarfCore package
    /// test file were silently unscanned — and its only self-check caught
    /// deletions, never omissions. `legacySuiteFiles` keeps the old names as
    /// a floor (each must still be found), and `phaseSuiteFloor` keeps the
    /// population from collapsing if the matcher ever stops matching.
    static func isPhaseSuite(_ name: String) -> Bool {
        guard name.hasSuffix("Tests.swift") else { return false }
        return name.range(of: "P[0-9]+[a-z]?", options: .regularExpression) != nil
    }

    /// The round-3/round-4 names the pattern replaced. Every one must still
    /// be scanned; a rename that drops the phase number fails here.
    static let legacySuiteFiles: Set<String> = [
        "HermesCLIVerdictP31Tests.swift", "HermesConfigUnsetP35Tests.swift",
        "HermesCronRecoveryP30Tests.swift", "HermesCronRecoveryP38Tests.swift",
        "HermesP32YAMLUnificationTests.swift", "HermesP37RemediationTests.swift",
        "HermesP38YAMLPurgeTests.swift", "SettingsEditorClearP35Tests.swift",
        "BotDraftControlCharacterP32Tests.swift", "ConfigReadProofP33Tests.swift",
        "CronRecoveryOfferP30Tests.swift", "CronRecoveryP38Tests.swift",
        "GatewayPairingVerdictP31Tests.swift", "HermesP35MCPTokenProbeTests.swift",
        "HermesP35SelectionAndFloorsTests.swift", "HermesP38SettingsResidueTests.swift",
        "MainActorSpawnDisciplineP22Tests.swift",
        "HermesManagedRefusalP39Tests.swift", "HermesConfigSetP39Tests.swift",
        "HermesManagedInstallP39Tests.swift",
    ]

    /// The base of `fix/whole-surface-audit-r4`. The branch scope below is
    /// `git diff --name-only <this>..HEAD -- '*Tests.swift'`.
    static let branchBase = "5be08f2e"

    /// Scope (ii), P46 finding 3: **every test file this branch touched**,
    /// whether or not its name carries a phase number.
    ///
    /// The name pattern alone is not a scope. P45 replaced a hand-kept
    /// allowlist with `isPhaseSuite`, which finds new PHASE suites by
    /// construction — but a phase that fixes sites in an existing,
    /// ordinarily-named suite (`M5FeatureVMTests.swift`, which P45 itself
    /// edited) writes code no sweep reads. Scoping by PATH — what the branch
    /// changed — closes that, and ``theBranchScopeMatchesGit`` keeps the list
    /// honest against `git` rather than against itself.
    ///
    /// Basenames, because the same suite name appears under two targets and
    /// both are in scope either way.
    static let branchTouchedTestFiles: Set<String> = [
        "AuditF2ArgvAndSecretSurfacingTests.swift",
        "BotAgentViewModelTests.swift",
        "BotModePhaseBP0Tests.swift",
        "BotRoutinesViewModelTests.swift",
        "ConfigReadProofP33Tests.swift",
        "CronArgvP42Tests.swift",
        "CronP15EditArgvTests.swift",
        "CronP18ClearGestureTests.swift",
        "CronRecoveryP38Tests.swift",
        "CronRecoveryP42Tests.swift",
        "CronRecoveryP42bTests.swift",
        "CronScheduleDisplayP42cTests.swift",
        "CronViewModelErrorClassificationTests.swift",
        "FleetApplyPlanTests.swift",
        "GatewayAndPluginsVerdictP40Tests.swift",
        "GatewayAndPluginsVerdictP40bTests.swift",
        "GatewayAndPluginsVerdictP40cTests.swift",
        "HermesCLIOptionP42Tests.swift",
        "HermesCLIVerdictP40Tests.swift",
        "HermesCapabilitiesTests.swift",
        "HermesConfigSetP39Tests.swift",
        "HermesConfigUnsetP35Tests.swift",
        "HermesCronKanbanP42bTests.swift",
        "HermesFileServiceConfigParityTests.swift",
        "HermesGatewayVerdictP40bTests.swift",
        "HermesGatewayVerdictP40cTests.swift",
        "HermesManagedInstallP39Tests.swift",
        "HermesManagedLockP39cTests.swift",
        "HermesManagedRefusalP39Tests.swift",
        "HermesManagedRefusalP39bTests.swift",
        "HermesManagedRefusalP39cTests.swift",
        "HermesP17RemediationTests.swift",
        "HermesP26CitationSweepTests.swift",
        "HermesP28CrossPhaseRemediationTests.swift",
        "HermesP35SelectionAndFloorsTests.swift",
        "HermesP37RemediationTests.swift",
        "HermesP38SettingsResidueTests.swift",
        "HermesP38SourceSweepTests.swift",
        "HermesP41ControlCharacterRefusalTests.swift",
        "HermesP41MCPScalarTests.swift",
        "HermesP41YAMLDecoderTests.swift",
        "HermesP41bRefusalTests.swift",
        "HermesP41bYAMLTests.swift",
        "HermesP44Tests.swift",
        "HermesP44bTests.swift",
        "HermesP45Tests.swift",
        "HermesP46Tests.swift",
        "HermesV0204SkillsParityTests.swift",
        "HermesV0211CronParityTests.swift",
        "KanbanModelsTests.swift",
        "LocalModelConfigPlanTests.swift",
        "LocalizationCatalogTests.swift",
        "M0bTransportTests.swift",
        "M5FeatureVMTests.swift",
        "MCPYAMLMapKeyP19Tests.swift",
        "MainActorBlockingWritesP11Tests.swift",
        "MainActorSpawnDisciplineP22Tests.swift",
        "OAuthFlowDrainP40Tests.swift",
        "ProcessAsyncWaitP43cTests.swift",
        "ProcessDrainP43Tests.swift",
        "ProjectTemplateBoundsP43Tests.swift",
        "SectionAuditF5KanbanTests.swift",
        "SectionAuditF5ManageAppTests.swift",
        "SettingsP20ConfigDefaultsTests.swift",
        "SlashMenuLogicTests.swift",
        "SpawnDisciplineP43Tests.swift",
    ]

    /// Scope = the phase-name pattern OR the branch's own touched files.
    static func isInSweepScope(_ name: String) -> Bool {
        isPhaseSuite(name) || branchTouchedTestFiles.contains(name)
    }

    /// Premise floor: 78 phase suites matched when round 4 widened the sweep.
    static let phaseSuiteFloor = 70

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
                guard url.lastPathComponent != Self.ownFileName,
                      Self.isInSweepScope(url.lastPathComponent) else { continue }
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
                        offenders.append("\(url.lastPathComponent):\(j + 1) — "
                                         + next.trimmingCharacters(in: .whitespaces))
                        break
                    }
                }
            }
        }
        #expect(scanned.count >= Self.phaseSuiteFloor, Comment(rawValue:
            "the phase-suite matcher found only \(scanned.count) files "
            + "(floor \(Self.phaseSuiteFloor)) — it has stopped matching"))
        #expect(Self.legacySuiteFiles.subtracting(scanned).isEmpty, Comment(rawValue:
            "legacy phase suites are no longer being scanned: "
            + Self.legacySuiteFiles.subtracting(scanned).sorted().joined(separator: ", ")))
        #expect(offenders.isEmpty, Comment(rawValue: """
            A subscript follows a count `#expect` with no guard between them. \
            `#expect` records and CONTINUES, so a wrong count runs straight \
            into an out-of-bounds trap and kills the test host: \
            \(offenders.joined(separator: "; "))
            """))
    }

    /// Deletion floor for scope (ii): every branch-touched file must still be
    /// found, or a rename has silently dropped it out of the sweep.
    @Test func theBranchScopeIsFullyScanned() {
        var scanned: Set<String> = []
        for root in Self.phaseSuiteRoots {
            for url in Self.swiftFiles(under: root)
            where Self.isInSweepScope(url.lastPathComponent) {
                scanned.insert(url.lastPathComponent)
            }
        }
        let missing = Self.branchTouchedTestFiles.subtracting(scanned)
        #expect(missing.isEmpty, Comment(rawValue:
            "branch-touched test files are no longer being scanned: "
            + missing.sorted().joined(separator: ", ")))
    }

    /// And the list is checked against `git`, not against itself — the exact
    /// self-check P45's `phaseSuiteFiles` was missing. A test file this
    /// branch touches without being added here fails right here.
    ///
    /// `git` unavailable (a sandbox with no binary, or a checkout without the
    /// base commit) records an issue rather than passing quietly: a scope pin
    /// that can silently no-op is the failure mode this test exists for.
    @Test func theBranchScopeMatchesGit() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", Self.repoRoot.path, "diff", "--name-only",
                          "\(Self.branchBase)..HEAD", "--", "*Tests.swift"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            Issue.record("git could not diff \(Self.branchBase)..HEAD — the branch scope is unpinned")
            return
        }
        let reported = Set(
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)).lastPathComponent }
        )
        #expect(!reported.isEmpty, "the git diff reported nothing — the pin has broken")
        let unlisted = reported.subtracting(Self.branchTouchedTestFiles)
        #expect(unlisted.isEmpty, Comment(rawValue:
            "this branch touched test files that are not in `branchTouchedTestFiles`, "
            + "so the stability sweeps do not read them: "
            + unlisted.sorted().joined(separator: ", ")))
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
                guard url.lastPathComponent != Self.ownFileName,
                      Self.isInSweepScope(url.lastPathComponent) else { continue }
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
    /// Two sites are allowed, with reasons, because their sleep is not a wait
    /// for an observable but the FIXTURE itself or a deliberate "nothing
    /// happened" window, which by construction has nothing to observe.
    static let allowedFixedSleeps: [String: String] = [
        "ProcessAsyncWaitP43cTests.swift:339":
            "the 3 s is the FIXTURE — EOF deliberately lands between the two "
            + "graces (1 s and 6 s) so the latch race is decided by construction, "
            + "not by luck; it runs on a background queue, not in the test body",
        "MainActorSpawnDisciplineP22Tests.swift:251":
            "the assertion is that the cancelled load did NOT reach its third "
            + "probe, so there is no observable to poll for; the window is one "
            + "probe delay (0.3 s) times three",
    ]

    @Test func noTestSleepsAFixedHalfSecondOrMore() {
        let pattern = #"(?:Task|Thread)\.sleep\([^)]*?([0-9][0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            Issue.record("the sleep sweep's pattern does not compile")
            return
        }
        var offenders: [String] = []
        var allowancesSeen: Set<String> = []
        for root in Self.phaseSuiteRoots {
            for url in Self.swiftFiles(under: root) {
                guard url.lastPathComponent != Self.ownFileName,
                      Self.isInSweepScope(url.lastPathComponent) else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in src.components(separatedBy: "\n").enumerated() {
                    guard !Self.isComment(line) else { continue }
                    let ns = line as NSString
                    for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
                    where m.numberOfRanges > 1 {
                        let digits = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "_", with: "")
                        guard let raw = Double(digits) else { continue }
                        let seconds: Double
                        if line.contains("nanoseconds") { seconds = raw / 1_000_000_000 }
                        else if line.contains("microseconds") { seconds = raw / 1_000_000 }
                        else if line.contains("milliseconds") { seconds = raw / 1_000 }
                        else { seconds = raw }
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
