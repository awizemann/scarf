import Foundation
import CryptoKit

/// Local disk cache for Hermes-synthesized speech audio, keyed by
/// (server identity, provider, voice fingerprint, text). A cache hit skips
/// the server entirely — local providers load models on cold start
/// (seconds) and cloud ones bill per character, so replaying the same
/// message twice must not pay the round trip again.
///
/// Entries live under `~/Library/Caches/scarf/tts` (injectable for tests)
/// — regenerable data, so the system may purge it and backups skip it —
/// as one JSON manifest per synthesis plus the chunk files it names:
///
///     <key>.json          {"format":"mp3","chunks":["<key>-00.mp3",…]}
///     <key>-00.mp3        audio bytes, magic-byte-verified before store
///                         (`format` is one of `playableFormats`)
///
/// The manifest is written LAST — its presence is the entry's validity
/// signal, so a crash mid-store leaves orphan chunks that eviction sweeps
/// but never a manifest pointing at missing files. Total size is capped
/// (`maxBytes`); overflow evicts whole entries oldest-first by manifest
/// mtime, which is bumped on every store so "oldest" tracks last use.
///
/// Deliberately NOT guarded with locks: the struct is immutable, and every
/// file operation is individually atomic (`.atomic` writes, manifest last).
/// Two overlapping synthesis tasks (a stopped one still finishing beside a
/// new one) can at worst evict or tear an entry, which reads as a plain
/// miss and re-synthesizes — never as wrong audio, because keys are
/// content hashes.
public struct HermesTTSCache: Sendable {

    /// Soft cap on total cached bytes. WAV at 24 kHz PCM16 mono is ~48 KB
    /// per second of speech; 256 MB holds roughly 90 minutes of cached
    /// audio — far beyond a session's worth of replayed messages, small
    /// enough to be a rounding error on any Mac that runs Hermes.
    public static let maxBytes: Int64 = 256 * 1024 * 1024

    /// Container extensions an entry may carry — the formats
    /// `HermesSpeechService` accepts for playback. Anything else in a
    /// manifest reads as a miss.
    public static let playableFormats: Set<String> = ["wav", "mp3", "flac", "aiff"]

    /// Root directory for cached entries. Production default lives under
    /// Caches (same `scarf/` root as the SSH snapshot cache); tests inject
    /// a temp directory.
    public let directory: URL

    /// This cache's effective size cap. Defaults to ``maxBytes``; tests
    /// inject a small one so a couple of kilobytes can exercise a real
    /// eviction pass instead of writing 256 MB of audio.
    public let capBytes: Int64

    public init(directory: URL? = nil, maxBytes: Int64 = HermesTTSCache.maxBytes) {
        self.capBytes = maxBytes
        if let directory {
            self.directory = directory
            return
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        self.directory = caches.appendingPathComponent("scarf", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
    }

    // MARK: - Keys

    /// Stable cache key for one synthesis. Everything that changes the
    /// produced audio participates: the synthesizing server (+ profile
    /// home — `HermesSpeechService.serverIdentity`), provider, the
    /// per-provider voice fingerprint (voice id, model, language, speed —
    /// see `HermesSpeechService.voiceFingerprint`), and the exact text.
    /// Each field is length-prefixed so no two field splits collide.
    public static func cacheKey(server: String, provider: String, voiceFingerprint: String, text: String) -> String {
        let material = [server, provider, voiceFingerprint, text]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Entry shape

    struct Manifest: Codable {
        var format: String
        var chunks: [String]
    }

    private func manifestURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    // MARK: - Read

    /// Cached chunks for `key`, in playback order. `nil` on any miss or
    /// inconsistency (no manifest, unreadable manifest, missing chunk) —
    /// callers treat nil as a plain miss and re-synthesize; a corrupt
    /// entry is deleted so it can't shadow a fresh store.
    public func cachedAudio(for key: String) -> [Data]? {
        let manifestURL = self.manifestURL(for: key)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              Self.playableFormats.contains(manifest.format),
              !manifest.chunks.isEmpty else { return nil }
        var chunks: [Data] = []
        for name in manifest.chunks {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let chunk = try? Data(contentsOf: url) else {
                // A manifest naming a missing chunk is a torn entry — drop
                // it entirely rather than serving partial speech.
                try? FileManager.default.removeItem(at: manifestURL)
                return nil
            }
            chunks.append(chunk)
        }
        return chunks
    }

    // MARK: - Write

    /// Persist verified audio chunks of container `format` (one of
    /// `playableFormats`) under `key` and evict overflow.
    /// Best-effort: a write failure leaves the cache merely cold, never
    /// corrupt, so all errors are swallowed by design.
    public func store(chunks: [Data], key: String, format: String = "wav") {
        guard !chunks.isEmpty, Self.playableFormats.contains(format) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let name = "\(key)-\(String(format: "%02d", index)).\(format)"
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try chunk.write(to: url, options: .atomic)
                names.append(name)
            } catch {
                // Partial entry without a manifest is invisible to reads;
                // leave the orphaned chunks for eviction to sweep.
                return
            }
        }
        let manifest = Manifest(format: format, chunks: names)
        if let data = try? JSONEncoder().encode(manifest) {
            // .atomic makes manifest presence binary: either the previous
            // entry or the complete new one, never a torn manifest.
            try? data.write(to: manifestURL(for: key), options: .atomic)
        }
        evictOverflow()
    }

    /// Remove entries (manifest + chunks) oldest-first until the directory
    /// is back under `maxBytes`. Best-effort; stat/list failures just end
    /// the pass early.
    private func evictOverflow() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        ) else { return }

        var stats: [(url: URL, size: Int64, mtime: Date)] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey, .isDirectoryKey
            ])
            guard values?.isDirectory != true else { continue }
            stats.append((url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
        }
        var all = Self.groupForEviction(files: stats)
        var total = all.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > capBytes else { return }

        // Oldest mtime first, by manifest mtime — chunks go with their
        // manifest, so the whole entry leaves or none of it does.
        all.sort { $0.mtime < $1.mtime }
        for entry in all {
            guard total > capBytes else { break }
            for url in entry.files {
                try? fm.removeItem(at: url)
            }
            total -= entry.totalBytes
        }
    }

    /// One eviction unit: a manifest plus the chunk files it owns, or the
    /// synthetic group that collects everything the cache doesn't recognize.
    struct Entry: Equatable {
        var files: [URL]
        var totalBytes: Int64
        var mtime: Date
    }

    /// Group already-stat'ed cache files into eviction units.
    ///
    /// Pure and order-independent on purpose: `contentsOfDirectory` returns
    /// files in an UNSPECIFIED order, so a chunk `<key>-NN.mp3` can be seen
    /// before its manifest `<key>.json`. The manifest therefore merges into
    /// whatever the stem already accumulated rather than replacing it —
    /// replacing dropped those chunks from both the total and the entry's
    /// file list, so they were never counted toward the cap and never
    /// deleted, and the directory could sit permanently over it.
    ///
    /// Orphan files (no manifest, unrecognized name) group under a single
    /// synthetic entry so they participate in eviction instead of
    /// accumulating forever after torn stores.
    static func groupForEviction(files: [(url: URL, size: Int64, mtime: Date)]) -> [Entry] {
        var byManifest: [String: Entry] = [:]
        var orphans = Entry(files: [], totalBytes: 0, mtime: .distantPast)
        for file in files {
            if file.url.pathExtension == "json" {
                let stem = file.url.deletingPathExtension().lastPathComponent
                var entry = byManifest[stem] ?? Entry(files: [], totalBytes: 0, mtime: .distantPast)
                entry.files.append(file.url)
                entry.totalBytes += file.size
                // The manifest's own mtime is the entry's age — `store()`
                // rewrites it on every use, so "oldest" tracks last use.
                entry.mtime = file.mtime
                byManifest[stem] = entry
            } else if let chunkOwner = chunkOwnerKey(path: file.url.path) {
                var entry = byManifest[chunkOwner] ?? Entry(files: [], totalBytes: 0, mtime: .distantPast)
                entry.files.append(file.url)
                entry.totalBytes += file.size
                byManifest[chunkOwner] = entry
            } else {
                orphans.files.append(file.url)
                orphans.totalBytes += file.size
                orphans.mtime = max(orphans.mtime, file.mtime)
            }
        }
        var all = Array(byManifest.values)
        if !orphans.files.isEmpty { all.append(orphans) }
        return all
    }

    /// `…/<key>-NN.<ext>` → `<key>`, or nil for unexpected shapes.
    private static func chunkOwnerKey(path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let range = name.range(of: "-\\d{2}\\.(wav|mp3|flac|aiff)$", options: .regularExpression) else { return nil }
        return String(name[name.startIndex..<range.lowerBound])
    }
}
