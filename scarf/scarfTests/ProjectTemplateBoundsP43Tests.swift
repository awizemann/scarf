import Foundation
import ScarfCore
import Testing
@testable import scarf

/// Round-4 P43: `enforceArchiveBounds` no longer fails OPEN.
///
/// The guard exists for an input Scarf does not trust — a `.scarftemplate`
/// from a catalog, a `scarf://` URL, or a file someone was sent — and its
/// two halves had both been lost:
///
/// * the listing spawn read stdout only AFTER its bounded poll, so an archive
///   chatty enough to fill the 64 KB pipe buffer ran the budget out; and
/// * the caller wrapped the whole thing in `try?`, so a listing that failed
///   for any reason skipped the entry-count and unpacked-size caps entirely.
///
/// Decision 16 makes an unreadable listing a REFUSAL.
@Suite("Template archive bounds (P43)")
struct ProjectTemplateBoundsP43Tests {

    static func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p43-tpl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The refusal

    @Test("a file unzip cannot list is refused, not waved through")
    func unlistableArchiveIsRefused() throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("not-really.scarftemplate")
        // Valid-looking name, bytes that are not a zip at all: `unzip -Zt`
        // exits non-zero with nothing on stdout.
        try Data("this is not a zip file, not even slightly".utf8).write(to: bogus)

        var thrown: Error?
        do {
            _ = try ProjectTemplateService().inspect(zipPath: bogus.path)
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        // Before the fix this reached `unzip` and surfaced ITS error instead,
        // having skipped both bomb caps on the way.
        #expect(
            "\(error)".contains("table of contents"),
            "expected the unreadable-listing refusal, got: \(error)"
        )
    }

    @Test("the unreadable-listing refusal is localized, not a bare literal")
    func refusalIsLocalized() {
        let sentence = ProjectTemplateService.unreadableListingRefusal
        #expect(!sentence.isEmpty)
        // The key is in `Localizable.xcstrings`; in the test host's `en` the
        // lookup returns the source string, which is the key itself.
        #expect(sentence.contains("decompression bomb"))
    }

    // MARK: - The listing parser

    /// `unzip -Zt` says `1 file,` for a single-entry archive and `N files,`
    /// for the rest. The old field walk knew only the plural, so a one-file
    /// template matched neither cap — harmless while the guard failed open,
    /// and a refusal of a legitimate template the moment it stopped.
    @Test("both the singular and plural listing shapes parse")
    func listingParserHandlesBothSpellings() throws {
        let one = try #require(ProjectTemplateService.parseArchiveListing(
            "1 file, 3 bytes uncompressed, 3 bytes compressed:  0.0%"))
        #expect(one.entries == 1)
        #expect(one.uncompressedBytes == 3)

        let many = try #require(ProjectTemplateService.parseArchiveListing(
            "12 files, 40960 bytes uncompressed, 8192 bytes compressed: 80.0%"))
        #expect(many.entries == 12)
        #expect(many.uncompressedBytes == 40960)
    }

    @Test("a listing that carries neither number does not parse")
    func listingParserRejectsNonListings() {
        #expect(ProjectTemplateService.parseArchiveListing("Empty zipfile.") == nil)
        #expect(ProjectTemplateService.parseArchiveListing("") == nil)
    }

    /// The parser's premise, checked against the real tool rather than a
    /// remembered format string.
    @Test("real unzip -Zt on a one-entry archive parses")
    func realSingleEntryListingParses() throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("hi\n".utf8).write(to: staging.appendingPathComponent("a.txt"))
        let archive = dir.appendingPathComponent("one.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-rqX", archive.path, "."]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        #expect(zip.waitUntilExit(timeout: 30))

        let listing = try ProjectTemplateService.runToolCapturingOutput(
            "/usr/bin/unzip", ["-Zt", archive.path], timeout: 30)
        let claims = try #require(
            ProjectTemplateService.parseArchiveListing(listing),
            "unzip -Zt printed a shape the parser does not know: \(listing)")
        #expect(claims.entries == 1)
    }

    // MARK: - The listing spawn

    /// The deadlock the `try?` was hiding: a child that writes past the
    /// 64 KB pipe buffer on a pipe nobody reads blocks in `write()` until the
    /// budget runs out. With the drain running concurrently with the wait it
    /// finishes normally and its stdout comes back whole.
    @Test("a child with 200 KB of stderr still returns its stdout in time")
    func chattyStderrDoesNotEatTheBudget() throws {
        let out = try ProjectTemplateService.runToolCapturingOutput(
            "/bin/sh",
            ["-c", "head -c 200000 /dev/zero | tr '\\000' 'x' 1>&2; echo listed"],
            timeout: 20)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "listed")
    }

    @Test("a child that never exits is refused inside its budget")
    func hangingListingIsBounded() throws {
        let started = Date()
        var thrown: Error?
        do {
            _ = try ProjectTemplateService.runToolCapturingOutput(
                "/bin/sh", ["-c", "sleep 30"], timeout: 0.5)
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a non-zero exit is a throw, not an empty listing")
    func nonZeroExitThrows() {
        var thrown: Error?
        do {
            _ = try ProjectTemplateService.runToolCapturingOutput(
                "/bin/sh", ["-c", "exit 9"], timeout: 20)
        } catch {
            thrown = error
        }
        // The old helper returned "" here, which parsed into no fields and so
        // checked nothing — the fail-open, one frame below the `try?`.
        #expect(thrown != nil)
    }
}
