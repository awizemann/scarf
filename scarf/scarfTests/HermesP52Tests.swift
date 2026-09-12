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

    private static let roots = [
        "scarf/scarf",
        "scarf/Scarf iOS",
        "scarf/Packages/ScarfCore/Sources",
    ]

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
    private static let blockingNeedles = [
        "enrichedEnvironment()",
        "loadState()",
    ]

    @Test("no blocking call is parked on the cooperative pool by `Task.detached`")
    func blockingCallsDoNotRideTaskDetached() {
        var offenders: [String] = []
        var scannedByRoot: [String: Int] = [:]

        for root in Self.roots {
            for url in Self.swiftFiles(under: root) {
                guard url.standardizedFileURL.path != Self.ownPath else { continue }
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scannedByRoot[root, default: 0] += 1
                for (i, line) in src.components(separatedBy: "\n").enumerated() {
                    let bare = line.trimmingCharacters(in: .whitespaces)
                    guard !bare.hasPrefix("//"), !bare.hasPrefix("*") else { continue }
                    guard bare.contains("Task.detached") else { continue }
                    guard Self.blockingNeedles.contains(where: { bare.contains($0) })
                    else { continue }
                    offenders.append("\(url.lastPathComponent):\(i + 1) — \(bare)")
                }
            }
        }

        // Premise floor, per root: a sweep that read nothing "passes".
        for root in Self.roots {
            #expect((scannedByRoot[root] ?? 0) > 0, Comment(rawValue:
                "the sweep read no Swift files under \(root) — the walk is broken"))
        }

        #expect(offenders.isEmpty, Comment(rawValue: """
            A blocking call sits inside a `Task.detached`. That is off the \
            MAIN actor but still on the cooperative pool — one thread per \
            core, unable to grow — so it parks a thread every other task in \
            the process is competing for (charter C10). Use \
            `OffPool.run { … }`, which gives the blocking work a thread of \
            its own: \(offenders.joined(separator: "; "))
            """))
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
