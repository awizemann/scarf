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
    func unlistableArchiveIsRefused() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("not-really.scarftemplate")
        // Valid-looking name, bytes that are not a zip at all: `unzip -Zt`
        // exits non-zero with nothing on stdout.
        try Data("this is not a zip file, not even slightly".utf8).write(to: bogus)

        var thrown: Error?
        do {
            _ = try await ProjectTemplateService().inspect(zipPath: bogus.path)
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

    // MARK: - The paths the refusal must NOT take (P43b)

    /// Build a zip in `dir` from the files `contents` describes
    /// (`name` -> byte count, all zeros so a huge member still costs ~nothing
    /// on disk and compresses to a few hundred KB).
    static func makeZip(in dir: URL, named: String, contents: [(String, Int)]) throws -> URL {
        let staging = dir.appendingPathComponent("staging-" + named)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, bytes) in contents {
            let url = staging.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        let archive = dir.appendingPathComponent(named)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-rqX", archive.path, "."]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        #expect(zip.waitUntilExit(timeout: 120))
        #expect(zip.terminationStatus == 0)
        return archive
    }

    /// The happy path the refusal must not eat. A guard that refuses
    /// everything is not a guard, and nothing pinned that a legitimate
    /// multi-file template still passes both ceilings.
    @Test("a legitimate multi-file template passes the bounds")
    func realTemplatePassesTheBounds() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.makeZip(in: dir, named: "ok.scarftemplate", contents: [
            ("template.json", 512),
            ("README.md", 2048),
            ("skills/demo/SKILL.md", 4096),
            ("project/src/main.swift", 1024),
        ])
        try await ProjectTemplateService().enforceArchiveBounds(zipPath: archive.path)
    }

    /// The entry-count ceiling, on a real archive rather than a parsed string.
    @Test("an archive past the entry ceiling is refused")
    func entryCeilingRefuses() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = ProjectTemplateService.maxTemplateEntries + 1
        let members = (0..<count).map { ("f/\($0).txt", 1) }
        let archive = try Self.makeZip(in: dir, named: "many.scarftemplate", contents: members)

        var thrown: Error?
        do { try await ProjectTemplateService().enforceArchiveBounds(zipPath: archive.path) }
        catch { thrown = error }
        let error = try #require(thrown, "\(count) entries is past the ceiling")
        #expect("\(error)".contains("files"), "\(error)")
        #expect(!"\(error)".contains("table of contents"),
                "refused for the wrong reason — the listing was readable: \(error)")
    }

    /// The unpacked-size ceiling, and the `1 file,` spelling `unzip -Zt`
    /// prints for a single-entry archive — which is the spelling the old
    /// parser did not know.
    ///
    /// **6 MB against a 4 MB ceiling, not 300 MB against the shipped 256 MB**
    /// (round-5 decision 8). The guard reads a DECLARED size out of the
    /// listing and compares it to a number; the size of that number is not
    /// the mechanism. The old fixture allocated, wrote and compressed 300 MB
    /// of zeros on every run to clear a constant, which was several seconds
    /// of the serial suite for no extra proof. The ceiling is a parameter
    /// now — the same test seam `listingTimeout` already had — and the
    /// shipped value is pinned separately below, so both halves are still
    /// covered and neither costs 300 MB.
    @Test("a one-member decompression bomb is refused on size")
    func unpackedSizeCeilingRefuses() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ceiling: Int64 = 4 * 1024 * 1024
        let bomb = 6 * 1024 * 1024
        #expect(Int64(bomb) > ceiling)
        let archive = try Self.makeZip(
            in: dir, named: "bomb.scarftemplate", contents: [("payload.bin", bomb)])
        // The premise: it got PAST the archive-size cap, so the refusal below
        // can only come from the declared unpacked size. Zeros compress to
        // almost nothing, so this holds by a wide margin.
        let onDisk = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size]
                      as? Int64) ?? 0
        #expect(onDisk < ProjectTemplateService.maxTemplateArchiveBytes,
                "the zip is \(onDisk) bytes — it would be refused on file size instead")

        var thrown: Error?
        do {
            try await ProjectTemplateService().enforceArchiveBounds(
                zipPath: archive.path, unpackedCeiling: ceiling)
        } catch { thrown = error }
        let error = try #require(thrown, "6 MB unpacked is past a 4 MB ceiling")
        #expect("\(error)".contains("expand to"), "\(error)")

        // And the same archive passes when the ceiling is above it — so the
        // refusal is the SIZE comparison and not the one-member listing.
        try await ProjectTemplateService().enforceArchiveBounds(
            zipPath: archive.path, unpackedCeiling: Int64(bomb) * 2)
    }

    /// The parameter above is a test seam; the value Scarf actually ships is
    /// what protects a user, so it is pinned on its own.
    @Test("the shipped unpacked ceiling is unchanged")
    func shippedUnpackedCeilingIsPinned() {
        #expect(ProjectTemplateService.maxTemplateUnpackedBytes == 256 * 1024 * 1024)
        #expect(ProjectTemplateService.maxTemplateArchiveBytes == 64 * 1024 * 1024)
    }

    /// `openRemoteURL` downloads to its own temp file and hands it to
    /// `openLocalFile`. A refusal — which is now the ANSWER for an archive
    /// whose listing cannot be read, so the common case for a hostile file —
    /// left that download on disk forever.
    @Test("a refused download does not strand its temp archive")
    @MainActor
    func refusedDownloadRemovesItsTempArchive() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloaded = dir.appendingPathComponent("downloaded.scarftemplate")
        try Data("not a zip".utf8).write(to: downloaded)

        let vm = TemplateInstallerViewModel(context: .local)
        vm.openLocalFile(downloaded.path, source: .url, removeArchiveWhenDone: true)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .failed = vm.stage { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed = vm.stage else {
            Issue.record("expected a refusal, got \(vm.stage)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: downloaded.path),
                "the refused download is still on disk")
    }

    /// And the file the USER picked is never removed — same entry point, the
    /// other side of the flag.
    @Test("a refused local file the user picked is left alone")
    @MainActor
    func refusedLocalFileIsKept() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("mine.scarftemplate")
        try Data("not a zip".utf8).write(to: mine)

        let vm = TemplateInstallerViewModel(context: .local)
        vm.openLocalFile(mine.path)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .failed = vm.stage { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: mine.path),
                "Scarf deleted a file the user chose")
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
    func realSingleEntryListingParses() async throws {
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

        let listing = try await ProjectTemplateService.runToolCapturingOutput(
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
    func chattyStderrDoesNotEatTheBudget() async throws {
        let out = try await ProjectTemplateService.runToolCapturingOutput(
            "/bin/sh",
            ["-c", "head -c 200000 /dev/zero | tr '\\000' 'x' 1>&2; echo listed"],
            timeout: 20)
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == "listed")
    }

    @Test("a child that never exits is refused inside its budget")
    func hangingListingIsBounded() async throws {
        let started = Date()
        var thrown: Error?
        do {
            _ = try await ProjectTemplateService.runToolCapturingOutput(
                "/bin/sh", ["-c", "sleep 30"], timeout: 0.5)
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a non-zero exit is a throw, not an empty listing")
    func nonZeroExitThrows() async {
        var thrown: Error?
        do {
            _ = try await ProjectTemplateService.runToolCapturingOutput(
                "/bin/sh", ["-c", "exit 9"], timeout: 20)
        } catch {
            thrown = error
        }
        // The old helper returned "" here, which parsed into no fields and so
        // checked nothing — the fail-open, one frame below the `try?`.
        #expect(thrown != nil)
    }
}
