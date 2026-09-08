import Testing
import Foundation

/// GW-E1 — the guarded-write enforcement seam.
///
/// The transport's raw write primitive is named `unguardedWriteFile`, and
/// `ServerContext.unguardedWriteText` is the one helper seam left that wraps
/// it (GW-E2a deleted `HermesFileService`'s private twin by converting all
/// five of its callers). The rename makes an unguarded write impossible to
/// perform *by accident* — you have to type the word.
///
/// ## What this scanner does and does NOT cover (GW-F5 / SEC F4)
///
/// It used to claim it made an unguarded write "impossible to perform
/// silently". It does not, and saying so invited exactly the trust it can't
/// carry. Honestly:
///
/// - **Covered:** every direct CALL of the transport primitive in non-test
///   sources must name itself with an annotation (rule 2), and the old,
///   innocent-looking names cannot come back (rule 1).
/// - **NOT covered — wrapper laundering.** One annotated helper with N
///   callers is one annotation, and the N call sites are invisible to a
///   line-based scan. Nothing here can see them; a REVIEWER has to, which
///   is why the annotation asks for a reason and not just a class letter.
/// - **NOT covered — Foundation writes in general.** `Data.write(to:)`,
///   `FileManager.createFile`, `FileHandle`, `String.write(to:)` all reach
///   the disk without touching a transport. Twelve such sites exist and
///   most are legitimate (export sheets, save panels, temp staging), so a
///   blanket ban would be false-positive noise. Rule 3 below therefore
///   bans only the narrow case that is never legitimate: a Foundation write
///   aimed at one of Scarf's OWN live-state files.
/// - **Not an evasion:** `#if` branches. The scan is textual, so it sees
///   both sides of a conditional — more than the compiler does, not less.
///
/// Three rules, all line-based and deliberately dumb (a full parse would be
/// slower and no more correct for a naming convention):
///
/// 1. **No `.writeFile(` / `.writeText(` on a transport or context anywhere in
///    non-test sources.** The old names no longer exist; a match means someone
///    reintroduced a shim, or a new transport-shaped type grew a `writeFile`
///    that will be mistaken for a guarded one.
///
/// 2. **Every `unguardedWriteFile(` / `unguardedWriteText(` CALL SITE carries an
///    `// UNGUARDED-WRITE(<G|C|O|R>): <reason>` annotation** on the same line or
///    on a preceding line that IS A COMMENT. Classes: `G` guard-internal, `C`
///    create-only scaffold, `O` authoritative overwrite, `R` destroy-shaped
///    read-modify-write (the E2 conversion backlog).
///
/// 3. **No Foundation write may target a Scarf-owned live-state file.**
///    A `Data.write` / `createFile` on a line that also spells
///    `servers.json`, `projects.json`, `config.yaml`, `.env`, `MEMORY.md`
///    … in a string literal is a write around the whole discipline. Only
///    the transports and the guards themselves may name those files that
///    way. See `liveStateBasenames`.
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

    /// Memoized (GW-F6 / audit PERF M5). Four `@Test`s each walked ~555
    /// files and re-read every one into a `String` — about 28 MB of
    /// allocation per run, three quarters of it identical. The corpus is
    /// immutable for the lifetime of the process, so it is read once.
    ///
    /// `nonisolated(unsafe)` + a lock rather than a plain `static let`
    /// because the read can throw and the tests run in parallel.
    private nonisolated(unsafe) static var cachedFiles: [(rel: String, text: String)]?
    private static let cacheLock = NSLock()

    private static func swiftFiles() throws -> [(rel: String, text: String)] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedFiles { return cachedFiles }
        let scanned = try scanSwiftFiles()
        cachedFiles = scanned
        return scanned
    }

    private static func scanSwiftFiles() throws -> [(rel: String, text: String)] {
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
                // The previous line only counts as THE ANNOTATION LINE when
                // it is a comment (GW-F5 / SEC F4). Without that test, an
                // inline-annotated call laundered its annotation to the call
                // on the next line — two unguarded writes, one reason, and
                // the second one never named itself.
                let previous = i > 0 ? lines[i - 1] : ""
                let annotated = line.contains("UNGUARDED-WRITE(")
                    || (Self.isComment(previous) && previous.contains("UNGUARDED-WRITE("))
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

    // MARK: - Rule 3: no Foundation write at a Scarf-owned live-state file

    /// The files whose read-modify-write discipline this whole arc exists to
    /// protect. Naming one of these in a string literal ON a write line means
    /// the writer went around the transports, the guards, the `.bak`, the
    /// damage refusal and the private-mode chmod all at once.
    ///
    /// Deliberately a SHORT list of live state, not "every file Scarf
    /// writes": exports, save panels, temp staging and caches are legitimate
    /// Foundation writes and must stay quiet, which is what keeps this rule
    /// worth having.
    private static let liveStateBasenames = [
        "servers.json", "projects.json", "project.json", "manifest.json",
        "miniapp_grants.json", "session_project_map.json", "model_presets.json",
        "config.yaml", "auth.json", ".env", "MEMORY.md", "USER.md",
    ]

    /// The only files allowed to spell those names next to a raw write: the
    /// transports (which ARE the write primitive) and the guards (which
    /// implement the discipline). Everything else goes through them.
    private static let liveStateWriteExempt = [
        "Transport/LocalTransport.swift",
        "Transport/SSHTransport.swift",
        "Transport/CitadelServerTransport.swift",
        "Services/GuardedJSONStore.swift",
        "Services/GuardedTextFile.swift",
        "Services/GuardedSidecarStore.swift",
    ]

    /// Double-quoted literals on a line, cheaply (no escape handling — a
    /// filename with an escaped quote in it is not a thing).
    private static func quotedLiterals(in line: String) -> [String] {
        let parts = line.components(separatedBy: "\"")
        guard parts.count > 2 else { return [] }
        return stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
    }

    @Test func noFoundationWriteTargetsScarfLiveState() throws {
        var offenders: [String] = []
        for (rel, text) in try Self.swiftFiles() {
            if Self.liveStateWriteExempt.contains(where: { rel.hasSuffix($0) }) { continue }
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(raw)
                guard line.contains(".write(") || line.contains("createFile(") else { continue }
                if Self.isComment(line) { continue }
                let named = Self.quotedLiterals(in: line).contains { literal in
                    let base = (literal as NSString).lastPathComponent
                    // `<name>.bak` / `<name>.corrupt-<stamp>` are the same
                    // file's bytes under another name — see
                    // `TransportPrivateMode.originalBasename`.
                    let stem = base.hasSuffix(".bak") ? String(base.dropLast(4)) : base
                    let root = stem.components(separatedBy: ".corrupt-").first ?? stem
                    return Self.liveStateBasenames.contains(root)
                }
                if named {
                    offenders.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, """
            A Foundation write is naming one of Scarf's live-state files. Those \
            files are written through a guard (`GuardedTextFile`, \
            `GuardedSidecarStore`) and nothing else — a raw write skips the \
            damage refusal, the one-deep `.bak` and the 0600 mode at once. Sites:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// Sanity: the scan is actually reaching sources. A root that silently
    /// resolves to nothing would make every rule above vacuously true.
    @Test func scanReachesTheSourceTree() throws {
        let files = try Self.swiftFiles()
        #expect(files.count > 200, "only \(files.count) sources found — source roots did not resolve")
        let annotated = files.filter { $0.text.contains("UNGUARDED-WRITE(") }.count
        // A "did the scan resolve" floor, NOT a budget: the allowlist is
        // meant to shrink, and E2's conversions do shrink it (E2c alone took
        // it from 21 annotated files to 19). Keep this well under the current
        // count so a real conversion never has to argue with it — but above
        // zero, because a root that resolved to nothing would make every rule
        // in this suite vacuously true. The G sites inside the guards
        // themselves are permanent and are most of what remains.
        #expect(annotated >= 8, "only \(annotated) annotated files — source roots did not resolve")
    }
}
