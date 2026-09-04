import Foundation
import CryptoKit
#if canImport(os)
import os
#endif

/// The read-then-write discipline every Scarf-owned JSON sidecar owes its
/// writers, factored out of `projects.json`'s hand-rolled version.
///
/// **Why this exists.** Every one of these files is a whole-file
/// read-modify-write: load, mutate in memory, replace. Written naively
/// (`try? decode ?? []` then `write`) that shape DESTROYS the file on the
/// first read failure — the empty list a failed read handed back gets
/// published as the truth. `projects.json` learned this the hard way
/// (commit 7460cf9); `miniapp_grants.json` and `session_project_map.json`
/// had the identical hole until t-3b855719, and `project.json` until
/// t-a6f22379.
///
/// **The discipline, in one place:**
/// 1. ABSENT vs UNREADABLE takes PROOF, never inference. A read failure is
///    only damage when a `stat` CONFIRMS the file AND a retried read fails
///    too — because over SSH `readFile` is `cat`, and one dropped
///    round-trip would otherwise fabricate damage on a healthy remote and
///    freeze every write. No stat ⇒ ABSENT ⇒ nothing is refused (the write
///    then fails on its own with the real transport error). Both probes
///    run only on the failure path; a healthy load is still ONE read.
/// 2. ZERO BYTES is damage, not an empty document: Scarf never writes a
///    zero-length JSON file, so somebody else truncated it.
/// 3. UNPARSEABLE is not UNREADABLE. Bytes we hold but cannot decode are
///    copied aside (`<name>.corrupt-<stamp>`) and then treated as ABSENT,
///    so the store can rebuild — the same call `ProjectStore` makes for
///    `project.json`. `projects.json` deliberately does NOT do this: its
///    rows are the user's projects and exist nowhere else, so it refuses
///    forever until a human intervenes. These sidecars are rebuildable
///    indices (a grant is re-granted by the permission sheet; an
///    attribution is re-recorded on the next chat), and a permanently
///    frozen grants file would be worse than a quarantined one.
/// 4. A write keeps a one-deep `.bak` of the bytes it replaces, and
///    publishes through `transport.writeFile`, which is atomic on all
///    three transports.
///
/// Everything is `nonisolated` and transport-based, so Mac and iOS share
/// the code path exactly as the stores that use it do.
public struct GuardedJSONStore: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "GuardedJSONStore")
    #endif

    /// What the file on disk turned out to be.
    public enum State: Sendable, Equatable {
        /// Nothing there (or nothing we can prove is there) — safe to write.
        case absent
        /// Bytes we read and can hand to a decoder.
        case present
        /// The file is stat-confirmed but two reads failed, or it is zero
        /// bytes. Writing would replace content we never saw.
        case unreadable(path: String)
        /// We held the bytes but they were unusable (undecodable, or past
        /// the size cap); they were copied to `copy`. Treated as writable —
        /// see rule 3 above.
        case quarantined(copy: String)
    }

    public struct Inspection: Sendable {
        public var state: State
        /// The bytes behind `.present` (and behind `.quarantined`, so a
        /// caller can still look at them). `nil` otherwise.
        public var bytes: Data?

        public var isDamaged: Bool {
            if case .unreadable = state { return true }
            return false
        }
    }

    public let transport: any ServerTransport
    /// Short name used in log lines (`"miniapp_grants.json"`).
    public let label: String

    public nonisolated init(transport: any ServerTransport, label: String) {
        self.transport = transport
        self.label = label
    }

    // MARK: - Read

    /// One read answering every question a guarded write has to ask: is
    /// this damage, what should the `.bak` capture, and what should the
    /// decoder see. Reading per question would be one SSH/SFTP round-trip
    /// per question.
    ///
    /// - Parameter maxBytes: anything larger is unusable and is quarantined
    ///   rather than decoded — a memory-pressured phone must not try.
    public nonisolated func inspect(_ path: String, maxBytes: Int) -> Inspection {
        var read = try? transport.readFile(path)
        if read == nil {
            guard let info = transport.stat(path) else {
                return Inspection(state: .absent, bytes: nil)
            }
            read = try? transport.readFile(path)
            if read == nil {
                #if canImport(os)
                Self.logger.error(
                    "\(self.label, privacy: .public) at \(path, privacy: .public) exists (\(info.size) bytes) but could not be read twice; treating as damaged"
                )
                #endif
                return Inspection(state: .unreadable(path: path), bytes: nil)
            }
        }
        guard let data = read else { return Inspection(state: .absent, bytes: nil) }
        guard !data.isEmpty else {
            #if canImport(os)
            Self.logger.error(
                "\(self.label, privacy: .public) at \(path, privacy: .public) is zero bytes; treating as damaged"
            )
            #endif
            return Inspection(state: .unreadable(path: path), bytes: data)
        }
        if data.count > maxBytes {
            #if canImport(os)
            Self.logger.warning(
                "\(self.label, privacy: .public) at \(path, privacy: .public) is \(data.count) bytes (cap \(maxBytes)); quarantining"
            )
            #endif
            return quarantining(data: data, path: path)
        }
        return Inspection(state: .present, bytes: data)
    }

    /// Decode `path`, quarantining bytes that will not decode.
    ///
    /// The decode failure is NOT a refusal: the corrupt bytes now exist in
    /// the quarantine copy, so the store may rebuild from empty (rule 3).
    /// A transport-level failure still reports `.unreadable`, which the
    /// writer refuses.
    public nonisolated func inspectDecoding<T: Decodable>(
        _ type: T.Type,
        at path: String,
        maxBytes: Int,
        decoder: JSONDecoder = JSONDecoder()
    ) -> (inspection: Inspection, value: T?) {
        let inspection = inspect(path, maxBytes: maxBytes)
        guard case .present = inspection.state, let data = inspection.bytes else {
            return (inspection, nil)
        }
        do {
            return (inspection, try decoder.decode(type, from: data))
        } catch {
            #if canImport(os)
            Self.logger.error(
                "\(self.label, privacy: .public) at \(path, privacy: .public) could not be decoded: \(error.localizedDescription, privacy: .public); quarantining"
            )
            #endif
            return (quarantining(data: data, path: path), nil)
        }
    }

    // MARK: - Write

    /// Publish `data` over `path`, refusing when the predecessor was
    /// damage and keeping a one-deep `.bak` of what it replaces.
    ///
    /// - Parameter inspection: the inspection this write is based on. Pass
    ///   the SAME one the caller decoded from — re-inspecting here would
    ///   both cost a second round-trip and open a fresh read-then-write
    ///   window.
    public nonisolated func write(
        _ data: Data,
        to path: String,
        after inspection: Inspection
    ) throws {
        if case .unreadable(let damagedPath) = inspection.state {
            throw GuardedStoreError.refusedUnreadableOverwrite(path: damagedPath, label: label)
        }
        let parent = (path as NSString).deletingLastPathComponent
        // `createDirectory` is mkdir -p on every transport.
        try transport.createDirectory(parent)

        if let existing = inspection.bytes, !existing.isEmpty, existing != data {
            // Best effort: losing the backup is not a reason to fail the
            // write the user asked for.
            do {
                try transport.writeFile(path + ".bak", data: existing)
            } catch {
                #if canImport(os)
                Self.logger.warning(
                    "Could not refresh \(self.label, privacy: .public).bak: \(error.localizedDescription, privacy: .public)"
                )
                #endif
            }
        }
        try transport.writeFile(path, data: data)
    }

    // MARK: - Quarantine

    private nonisolated func quarantining(data: Data, path: String) -> Inspection {
        if let copy = Self.quarantine(data: data, path: path, transport: transport, label: label) {
            return Inspection(state: .quarantined(copy: copy), bytes: data)
        }
        // A failed copy must NOT look clean: the bytes would then exist
        // nowhere and the next write would be their end.
        return Inspection(state: .unreadable(path: path), bytes: data)
    }

    /// Copy unusable bytes aside as `<name>.corrupt-<stamp>` and return
    /// where they landed. Goes through the transport, so it behaves the
    /// same over SSH/SFTP as locally.
    ///
    /// Deduplicated against existing quarantine copies by size-then-bytes:
    /// these loads run on watcher ticks and a corrupt file stays corrupt
    /// until a human fixes it, so one copy per load would bury the
    /// directory.
    public nonisolated static func quarantine(
        data: Data,
        path: String,
        transport: any ServerTransport,
        label: String
    ) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".corrupt-"
        // MEMOIZED. A corrupt file stays corrupt until a human fixes it,
        // and these loads run on watcher ticks — so the dedup scan below
        // (`listDirectory` + a `stat` and a `readFile` per existing copy)
        // was paying 1 + 2K transport round-trips SEVERAL TIMES A SECOND
        // for an answer that had not changed since the first one. The memo
        // is keyed by the exact bytes, so different corruption still
        // scans, and it expires so a human deleting the quarantine copy is
        // noticed within a window rather than never.
        if let remembered = QuarantineMemo.shared.copy(forPath: path, bytes: data) {
            return remembered
        }
        if let names = try? transport.listDirectory(dir) {
            for name in names where name.hasPrefix(prefix) {
                let candidate = dir + "/" + name
                guard transport.stat(candidate)?.size == Int64(data.count) else { continue }
                if let existing = try? transport.readFile(candidate), existing == data {
                    QuarantineMemo.shared.remember(candidate, forPath: path, bytes: data)
                    return candidate
                }
            }
        }
        // Second-resolution stamp, so two DIFFERENT corruptions inside one
        // second don't land on the same name with the later eating the
        // earlier.
        var destination = dir + "/" + prefix + quarantineStamp(Date())
        if transport.fileExists(destination) {
            destination += "-" + UUID().uuidString.prefix(8)
        }
        do {
            try transport.writeFile(destination, data: data)
            #if canImport(os)
            logger.error(
                "Quarantined unusable \(label, privacy: .public) to \(destination, privacy: .public)"
            )
            #endif
            QuarantineMemo.shared.remember(destination, forPath: path, bytes: data)
            pruneQuarantineCopies(dir: dir, prefix: prefix, transport: transport)
            return destination
        } catch {
            #if canImport(os)
            logger.error(
                "Could not quarantine \(label, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            #endif
            return nil
        }
    }

    /// How many `<name>.corrupt-*` copies of one file are kept.
    static let quarantineKeepCount = 5

    /// Keep the newest `quarantineKeepCount` copies and delete the rest.
    ///
    /// Runs only after a copy was actually WRITTEN — a rare event — so it
    /// costs nothing on the tick path the memo above protects. The stamp
    /// format sorts lexicographically in time order by construction, and
    /// the `-<uuid8>` collision suffix sorts after its own second, so a
    /// name sort is a chronological sort here.
    ///
    /// An unbounded set is not merely untidy: every entry is a file the
    /// dedup scan reads in full whenever the memo is cold.
    private nonisolated static func pruneQuarantineCopies(
        dir: String, prefix: String, transport: any ServerTransport
    ) {
        guard let names = try? transport.listDirectory(dir) else { return }
        let copies = names.filter { $0.hasPrefix(prefix) }.sorted()
        guard copies.count > quarantineKeepCount else { return }
        for name in copies.dropLast(quarantineKeepCount) {
            let doomed = dir + "/" + name
            try? transport.removeFile(doomed)
            QuarantineMemo.shared.forget(copy: doomed)
        }
    }

    /// Filename-safe UTC stamp (`20260903T142530Z`). Deliberately not
    /// ISO-8601-with-colons: legal on APFS, not on every remote filesystem
    /// Scarf writes to over SSH.
    public nonisolated static func quarantineStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}

/// "These exact bytes at this exact path are already quarantined, and the
/// copy is over there."
///
/// Process-wide rather than per-store because the stores are `struct`s
/// built per call — a corrupt `miniapp_grants.json` is inspected through a
/// fresh `GuardedJSONStore` on every watcher tick, so an instance-scoped
/// memo would never hit.
///
/// **The invalidation edge is time.** The memo answers a question about
/// the remote filesystem, and the user can delete the quarantine copy
/// behind our back; entries therefore expire, after which the next
/// inspection pays the full scan again and re-establishes (or corrects)
/// the answer. Pruning also forgets what it deletes, so the memo can never
/// point at a copy this process itself removed.
final class QuarantineMemo: @unchecked Sendable {
    static let shared = QuarantineMemo()

    /// Long enough that a corrupt file being re-inspected several times a
    /// second costs one scan rather than thousands; short enough that a
    /// human cleaning up the quarantine directory is noticed while they
    /// are still at the keyboard.
    static let ttl: TimeInterval = 300

    private struct Entry {
        var copy: String
        var digest: String
        var at: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func copy(forPath path: String, bytes: Data) -> String? {
        let digest = Self.digest(bytes)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.digest == digest,
              Date().timeIntervalSince(entry.at) < Self.ttl
        else { return nil }
        return entry.copy
    }

    func remember(_ copy: String, forPath path: String, bytes: Data) {
        let digest = Self.digest(bytes)
        lock.lock()
        defer { lock.unlock() }
        entries[path] = Entry(copy: copy, digest: digest, at: Date())
    }

    /// Drop any memo pointing at a copy that no longer exists.
    func forget(copy: String) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.copy != copy }
    }

    /// Test seam.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    private static func digest(_ data: Data) -> String {
        // Content identity, not a security boundary — but SHA-256 is
        // free here and a truncated non-cryptographic hash on
        // attacker-writable bytes is exactly the shape the audit
        // objected to elsewhere.
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a guarded sidecar write was refused. Distinct from `TransportError`
/// so a caller can tell "the disk said no" from "we refused to do this".
public enum GuardedStoreError: LocalizedError, Sendable, Equatable {
    /// The file is provably there but its bytes could not be read (twice),
    /// or it is zero-length. Writing would replace content nobody has seen
    /// with content rebuilt from a read that failed.
    case refusedUnreadableOverwrite(path: String, label: String)

    public var errorDescription: String? {
        switch self {
        case let .refusedUnreadableOverwrite(path, label):
            return "\(label) at \(path) exists but couldn't be read; refusing to overwrite it."
        }
    }
}
