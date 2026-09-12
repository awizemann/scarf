import Testing
import Foundation
@testable import scarf

/// Round-5 P48b — the process-global analytics seam, swept.
///
/// P48 gave `AppCoordinator` a `usageTracker` parameter precisely so a test
/// that merely NEEDS a coordinator stops emitting `section_viewed` into
/// `Analytics`'s one installed slot — but it only converted the suites whose
/// subject was the seam, and three sites in two other files kept building a
/// bare `AppCoordinator()`. Running in parallel with
/// `AnalyticsFeatureUsageEventsTests`, whose assertions are exact equality on
/// the captured event list, that is a cross-file flake with no local symptom.
///
/// A sweep rather than three fixed call sites, because the next one will be
/// written by someone who has never read this note.
@Suite("The analytics seam is injected, never inherited (P48b)")
struct AnalyticsSeamInjectionP48bTests {

    private static var testRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// This file names the offending spelling in its own prose and in its
    /// failure message, so it must exempt itself — by PATH, never by
    /// BASENAME (P49b's lesson, restated by P52 and applied here in round-6
    /// P53: a basename exemption silently covers any future same-named file
    /// in a subdirectory this sweep now walks).
    private static let ownPath = URL(fileURLWithPath: #filePath)
        .standardizedFileURL.path

    @Test("no test builds an AppCoordinator without its own tracker")
    func noBareCoordinatorInTests() throws {
        // RECURSIVE. `contentsOfDirectory` reads one level, so a test moved
        // into a subdirectory of `scarfTests` left the sweep — and the sweep
        // exists because "the next bare construction will be written by
        // someone who has never read this note" (round-6 P53).
        let walker = try #require(
            FileManager.default.enumerator(at: Self.testRoot, includingPropertiesForKeys: nil),
            "could not enumerate \(Self.testRoot.path)")
        var files: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        #expect(files.count >= 100, "the sweep read only \(files.count) files — it cannot have covered scarfTests")

        var offenders: [String] = []
        for url in files where url.standardizedFileURL.path != Self.ownPath {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in src.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), line.contains("AppCoordinator()") else { continue }
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: """
            A test builds `AppCoordinator()` with no tracker. Its `init` reports \
            `section_viewed` to whatever is installed in `Analytics`'s \
            process-global slot, so under parallel testing it lands in another \
            suite's captured events: \(offenders.joined(separator: ", ")). \
            Pass `AppCoordinator(usageTracker: NoopUsageTracker())`.
            """))
    }
}
