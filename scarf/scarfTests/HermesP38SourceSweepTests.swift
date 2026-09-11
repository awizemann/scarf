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
    /// **Scoped to the round-3/round-4 phase suites**, not the whole tree.
    /// A repo-wide run reports ~100 pre-existing sites, and fixing those is a
    /// separate mechanical pass (filed as `t-f43f0af5`) — a sweep that fails
    /// on day one is a sweep somebody disables. What it does buy: every suite
    /// this branch wrote is held to the rule, and a new phase suite that
    /// reintroduces the shape fails here.
    static let phaseSuiteFiles: Set<String> = [
        "HermesCLIVerdictP31Tests.swift", "HermesConfigUnsetP35Tests.swift",
        "HermesCronRecoveryP30Tests.swift", "HermesCronRecoveryP38Tests.swift",
        "HermesP32YAMLUnificationTests.swift", "HermesP37RemediationTests.swift",
        "HermesP38YAMLPurgeTests.swift", "SettingsEditorClearP35Tests.swift",
        "BotDraftControlCharacterP32Tests.swift", "ConfigReadProofP33Tests.swift",
        "CronRecoveryOfferP30Tests.swift", "CronRecoveryP38Tests.swift",
        "GatewayPairingVerdictP31Tests.swift", "HermesP35MCPTokenProbeTests.swift",
        "HermesP35SelectionAndFloorsTests.swift", "HermesP38SettingsResidueTests.swift",
        "MainActorSpawnDisciplineP22Tests.swift",
        // P39.
        "HermesManagedRefusalP39Tests.swift", "HermesConfigSetP39Tests.swift",
        "HermesManagedInstallP39Tests.swift",
    ]

    @Test func noSubscriptFollowsACountExpectation() {
        var offenders: [String] = []
        var scanned: Set<String> = []
        for root in Self.testRoots {
            for url in Self.swiftFiles(under: root) {
                guard Self.phaseSuiteFiles.contains(url.lastPathComponent) else { continue }
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
                        if next.contains(receiver + "[") {
                            offenders.append("\(url.lastPathComponent):\(j + 1) — "
                                             + next.trimmingCharacters(in: .whitespaces))
                            break
                        }
                    }
                }
            }
        }
        #expect(scanned == Self.phaseSuiteFiles, Comment(rawValue:
            "the scoped list names files that no longer exist: "
            + Self.phaseSuiteFiles.subtracting(scanned).sorted().joined(separator: ", ")))
        #expect(offenders.isEmpty, Comment(rawValue: """
            A subscript follows a count `#expect` with no guard between them. \
            `#expect` records and CONTINUES, so a wrong count runs straight \
            into an out-of-bounds trap and kills the test host: \
            \(offenders.joined(separator: "; "))
            """))
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
