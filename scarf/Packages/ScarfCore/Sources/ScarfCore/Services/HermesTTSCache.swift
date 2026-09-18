import Foundation
import CryptoKit

/// Local disk cache for Hermes-synthesized speech audio, keyed by
/// (provider, voice fingerprint, text). A cache hit skips the server
/// entirely — kokoro synthesis loads torch on cold start (seconds), so
/// replaying the same message twice must not pay the round trip again.
///
/// Entries live under `~/Library/Application Support/Scarf/TTSCache`
/// (injectable for tests) as one JSON manifest per synthesis plus the
/// chunk files it names:
///
///     <key>.json          {"format":"wav","chunks":["<key>-00.wav",…]}
///     <key>-00.wav        RIFF/WAVE bytes, magic-byte-verified before store
///
/// The manifest is written LAST — its presence is the entry's validity
/// signal, so a crash mid-store leaves orphan chunks that eviction sweeps
/// but never a manifest pointing at missing files. Total size is capped
/// (`maxBytes`); overflow evicts whole entries oldest-first by manifest
/// mtime, which is bumped on every store so "oldest" tracks last use.
///
/// Deliberately NOT `Sendable`-guarded with locks: the only production
/// caller is `HermesSpeechService` (an actor), so access is serialized by
/// the actor's executor. The struct itself is immutable beyond `directory`.
public struct HermesTTSCache: Sendable {

    /// Soft cap on total cached bytes. WAV at 24 kHz PCM16 mono is ~48 KB
    /// per second of speech; 256 MB holds roughly 90 minutes of cached
    /// audio — far beyond a session's worth of replayed messages, small
    /// enough to be a rounding error on any Mac that runs Hermes.
    public static let maxBytes: Int64 = 256 * 1024 * 1024

    /// Root directory for cached entries. Production default lives under
    /// Application Support; tests inject a temp directory.
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        self.directory = support.appendingPathComponent("Scarf", isDirectory: true)
            .appendingPathComponent("TTSCache", isDirectory: true)
    }

    // MARK: - Keys

    /// Stable cache key for one synthesis. Everything that changes the
    /// produced audio participates: provider, the per-provider voice
    /// fingerprint (voice id, language, speed, venv path for kokoro —
    /// see `HermesSpeechService.voiceFingerprint`), and the exact text.
    public static func cacheKey(provider: String, voiceFingerprint: String, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(provider)|\(voiceFingerprint)|\(text)".utf8))
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
              manifest.format == "wav",
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

    /// Persist verified WAV chunks under `key` and evict overflow.
    /// Best-effort: a write failure leaves the cache merely cold, never
    /// corrupt, so all errors are swallowed by design.
    public func store(chunks: [Data], key: String) {
        guard !chunks.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let name = "\(key)-\(String(format: "%02d", index)).wav"
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
        let manifest = Manifest(format: "wav", chunks: names)
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

        // Map every manifest to itself + its chunk files, with sizes and
        // mtimes. Orphan chunks (no manifest) group under a synthetic
        // entry so they participate in eviction instead of accumulating
        // forever after torn stores.
        struct Entry {
            var files: [URL]
            var totalBytes: Int64
            var mtime: Date
        }
        var byManifest: [String: Entry] = [:]
        var orphans = Entry(files: [], totalBytes: 0, mtime: .distantPast)
        for url in entries {
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey, .isDirectoryKey
            ])
            guard values?.isDirectory != true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate ?? .distantPast
            if url.pathExtension == "json" {
                let stem = url.deletingPathExtension().lastPathComponent
                byManifest[stem] = Entry(files: [url], totalBytes: size, mtime: mtime)
            } else if let chunkOwner = chunkOwnerKey(path: url.path) {
                var entry = byManifest[chunkOwner] ?? Entry(files: [], totalBytes: 0, mtime: .distantPast)
                entry.files.append(url)
                entry.totalBytes += size
                byManifest[chunkOwner] = entry
            } else {
                orphans.files.append(url)
                orphans.totalBytes += size
                orphans.mtime = max(orphans.mtime, mtime)
            }
        }
        var all = Array(byManifest.values)
        if !orphans.files.isEmpty { all.append(orphans) }
        var total = all.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > Self.maxBytes else { return }

        // Oldest mtime first. Chunks inherit their manifest's mtime (set
        // above from whichever file was newest in the group — close enough
        // for an overflow sweep whose goal is a bounded directory).
        all.sort { $0.mtime < $1.mtime }
        for entry in all {
            guard total > Self.maxBytes else { break }
            for url in entry.files {
                try? fm.removeItem(at: url)
            }
            total -= entry.totalBytes
        }
    }

    /// `…/<key>-NN.wav` → `<key>`, or nil for unexpected shapes.
    private func chunkOwnerKey(path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard let range = name.range(of: "-\\d{2}\\.wav$", options: .regularExpression) else { return nil }
        return String(name[name.startIndex..<range.lowerBound])
    }
}
