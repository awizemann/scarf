import Testing
import Foundation
@testable import ScarfCore

/// Disk eviction for the TTS cache. The bug these pin: `contentsOfDirectory`
/// returns files in an unspecified order, so a chunk can be enumerated
/// BEFORE the manifest that owns it — and the grouping must merge, never
/// replace, or those chunks count for nothing and outlive their entry.
@Suite struct HermesTTSCacheTests {

    // MARK: - Pure grouping (order-independent by construction)

    private func file(_ name: String, _ size: Int64, _ mtime: TimeInterval) -> (url: URL, size: Int64, mtime: Date) {
        (URL(fileURLWithPath: "/tmp/tts/\(name)"), size, Date(timeIntervalSince1970: mtime))
    }

    @Test func groupingMergesChunksSeenBeforeTheirManifest() throws {
        let entries = HermesTTSCache.groupForEviction(files: [
            file("aaa-00.mp3", 100, 10),
            file("aaa-01.mp3", 200, 10),
            file("aaa.json", 7, 50),
        ])
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.totalBytes == 307)
        #expect(entry.files.count == 3)
        // The manifest's mtime is the entry's age, whichever order it arrived in.
        #expect(entry.mtime == Date(timeIntervalSince1970: 50))
    }

    @Test func groupingIsOrderIndependent() {
        let files = [file("aaa-00.mp3", 100, 10), file("aaa.json", 7, 50), file("bbb.json", 7, 20)]
        // Normalized: an entry's file list is a set, so only its membership,
        // size and mtime are meant to be order-independent.
        func grouped(_ input: [(url: URL, size: Int64, mtime: Date)]) -> [[String]] {
            HermesTTSCache.groupForEviction(files: input)
                .sorted { $0.mtime < $1.mtime }
                .map { ["\($0.totalBytes)", "\($0.mtime.timeIntervalSince1970)"] + $0.files.map(\.lastPathComponent).sorted() }
        }
        let forward = HermesTTSCache.groupForEviction(files: files).sorted { $0.mtime < $1.mtime }
        #expect(grouped(files) == grouped(files.reversed()))
        #expect(forward.map(\.totalBytes) == [7, 107])
    }

    @Test func orphanChunksGroupSeparately() {
        let entries = HermesTTSCache.groupForEviction(files: [file("stray.txt", 9, 1)])
        #expect(entries.count == 1)
        #expect(entries.first?.totalBytes == 9)
    }

    // MARK: - End to end on disk

    @Test func storeEvictsWholeEntriesIncludingTheirChunks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tts-evict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HermesTTSCache(directory: root, maxBytes: 4_000)

        let old = HermesTTSCache.cacheKey(server: "s", provider: "p", voiceFingerprint: "v", text: "old")
        cache.store(chunks: [Data(repeating: 1, count: 3_000)], key: old, format: "mp3")
        // Age the old entry so "oldest-first" is unambiguous.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: root.appendingPathComponent("\(old).json").path
        )

        let new = HermesTTSCache.cacheKey(server: "s", provider: "p", voiceFingerprint: "v", text: "new")
        cache.store(chunks: [Data(repeating: 2, count: 3_000)], key: new, format: "mp3")

        let fm = FileManager.default
        #expect(cache.cachedAudio(for: new) != nil)
        #expect(cache.cachedAudio(for: old) == nil)
        // The bug: the evicted entry's CHUNK file survived while only its
        // manifest went, leaving the directory permanently over the cap.
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("\(old)-00.mp3").path))

        let total = (try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]))
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        #expect(total <= 4_000)
    }
}
