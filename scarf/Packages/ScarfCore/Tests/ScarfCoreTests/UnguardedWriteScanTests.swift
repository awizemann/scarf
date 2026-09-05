import Testing
import Foundation

/// GW-E1 — the guarded-write enforcement seam.
///
/// The transport's raw write primitive is named `unguardedWriteFile`, and
/// `ServerContext.unguardedWriteText` is the one helper seam left that wraps
/// it (GW-E2a deleted `HermesFileService`'s private twin by converting all
/// five of its callers). The rename makes an unguarded write
/// impossible to perform *by accident* — you have to type the word — and this
/// scanner makes it impossible to perform *silently*.
///
/// Two rules, both line-based and deliberately dumb (a full parse would be
/// slower and no more correct for a naming convention):
///
/// 1. **No `.writeFile(` / `.writeText(` on a transport or context anywhere in
///    non-test sources.** The old names no longer exist; a match means someone
///    reintroduced a shim, or a new transport-shaped type grew a `writeFile`
///    that will be mistaken for a guarded one.
///
/// 2. **Every `unguardedWriteFile(` / `unguardedWriteText(` CALL SITE carries an
///    `// UNGUARDED-WRITE(<G|C|O|R>): <reason>` annotation** on the same line or
///    the line above. Classes: `G` guard-internal, `C` create-only scaffold,
///    `O` authoritative overwrite, `R` destroy-shaped read-modify-write (the
///    E2 conversion backlog).
///
/// ## The escape hatch
///
/// **The annotation IS the escape hatch.** There is no allowlist file, no
/// `// swiftlint:disable`-style suppression, and no environment flag. If you
/// genuinely need a raw write, write the comment and say why in it — the cost
/// of an unguarded write is one line of prose that a reviewer, a `grep`, and
/// the E0 census can all see. Deleting the annotation to silence the scanner
/// fails the build; deleting the *call* is the other way out.
///
/// Declarations (`func unguardedWriteFile…`) and test targets are exempt: the
/// protocol and its conformances must be able to spell the primitive, and
/// tests write fixtures.
@Suite struct UnguardedWriteScanTests {

    // MARK: - Source root

    /// …/Tests/ScarfCoreTests/<this file> → up 4 = ScarfCore, up 6 = `scarf/`.
    /// Anchored on a file this suite owns so a moved package still resolves.
    private static var scarfDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // scarf/
    }

    /// Every non-test Swift source root in the repo: the Mac app, the iOS app
    /// target, and both packages' Sources trees.
    private static let sourceRoots = [
        "scarf",
        "Scarf iOS",
        "Packages/ScarfCore/Sources",
        "Packages/ScarfIOS/Sources",
    ]

    private static func swiftFiles() throws -> [(rel: String, text: String)] {
        var out: [(String, String)] = []
        for root in sourceRoots {
            let base = scarfDir.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let sub as String in e where sub.hasSuffix(".swift") {
                // Never scan build products or vendored checkouts.
                if sub.contains(".build/") || sub.contains("checkouts/") { continue }
                let url = base.appendingPathComponent(sub)
                out.append(("\(root)/\(sub)", try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    // MARK: - Rule 1: the old names are gone

    @Test func noTransportWriteFileOrWriteTextRemains() throws {
        var offenders: [String] = []
        for (rel, text) in try Self.swiftFiles() {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                // Cheap prefilter: the regex below is the slow path, and only
                // a line that literally contains `writeFile(`/`writeText(`
                // (lowercase `w`) can match it.
                guard s.contains("writeFile(") || s.contains("writeText(") else { continue }
                if Self.isComment(s) { continue }
                if s.contains(".writeFile(") || s.contains(".writeText(")
                    || s.range(of: #"(?<![A-Za-z_.])write(File|Text)\("#, options: .regularExpression) != nil {
                    offenders.append("\(rel):\(i + 1): \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, """
            The raw write primitive is `unguardedWriteFile` / `unguardedWriteText`. \
            A plain `writeFile(` / `writeText(` is either a resurrected shim or a new \
            writer that will be mistaken for a guarded one. Sites:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - Rule 2: every unguarded call site is annotated

    @Test func everyUnguardedWriteCallSiteIsAnnotated() throws {
        var offenders: [String] = []
        for (rel, text) in try Self.swiftFiles() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in lines.enumerated() {
                guard line.contains("unguardedWriteFile(") || line.contains("unguardedWriteText(") else { continue }
                if Self.isComment(line) { continue }
                // Declarations spell the primitive by necessity.
                if line.contains("func unguardedWrite") { continue }
                let previous = i > 0 ? lines[i - 1] : ""
                let annotated = line.contains("UNGUARDED-WRITE(") || previous.contains("UNGUARDED-WRITE(")
                if !annotated {
                    offenders.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, """
            Every unguarded write must carry `// UNGUARDED-WRITE(<G|C|O|R>): <reason>` \
            on the same or preceding line — the annotation IS the escape hatch. Sites:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The annotation's class letter has to be one of the four the census
    /// defines, so `UNGUARDED-WRITE(whatever)` can't be used as a wildcard.
    @Test func annotationClassesAreWellFormed() throws {
        var offenders: [String] = []
        for (rel, text) in try Self.swiftFiles() {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("UNGUARDED-WRITE(") {
                let s = String(line)
                if s.range(of: #"// UNGUARDED-WRITE\([GCOR]\): \S"#, options: .regularExpression) == nil {
                    offenders.append("\(rel):\(i + 1): \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, """
            Malformed annotation(s). Shape: `// UNGUARDED-WRITE(G|C|O|R): <reason>`:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Sanity: the scan is actually reaching sources. A root that silently
    /// resolves to nothing would make every rule above vacuously true.
    @Test func scanReachesTheSourceTree() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 200, "only \(files.count) sources found — source roots did not resolve")
        let annotated = files.filter { $0.text.contains("UNGUARDED-WRITE(") }.count
        #expect(annotated > 20, "only \(annotated) annotated files — the census listed far more")
    }
}
