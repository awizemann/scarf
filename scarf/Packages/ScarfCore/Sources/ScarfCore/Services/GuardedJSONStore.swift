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
///
/// **Writing a NEW store? Start at `GuardedSidecarStore`** (GW-E3), not
/// here. This type is the mechanism; that protocol is the adoption path —
/// it makes the rebuildable-vs-irreplaceable choice in rule 3 an explicit
/// per-file declaration (`damagePolicy`) and applies it to BOTH the decode
/// failure and the size cap, which is the branch a hand-rolled adopter
/// forgets. Its doc comment is the guide: which policy, which shape
/// (closure vs held inspection), unknown-key preservation, and `.bak`
/// semantics.
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
        /// The file is stat-confirmed but two reads failed, it is zero
        /// bytes, or it is past the size cap (in which case it was never
        /// read at all — see ``inspect(_:maxBytes:)``). Writing would
        /// replace content we never saw.
        case unreadable(path: String)
        /// We held the bytes and they would not DECODE; they were copied to
        /// `copy`. Treated as writable — see rule 3 above. (Bytes past the
        /// size cap are `.unreadable`, not this: they are refused before
        /// they are read, so there is nothing to copy aside.)
        case quarantined(copy: String)
    }

    public struct Inspection: Sendable {
        public var state: State
        /// The bytes behind `.present` (and behind `.quarantined`, so a
        /// caller can still look at them). `nil` otherwise.
        public var bytes: Data?
        /// Where unusable bytes were copied aside, when they were. Set on
        /// `.quarantined`, and DELIBERATELY PRESERVED when a
        /// `.refuseForever` store reclassifies that to `.unreadable`
        /// (`GuardedSidecarStore`): the write is refused, but the user still
        /// has to be told where their file went.
        public var quarantineCopy: String?

        /// `public` so out-of-module writers of NON-JSON text files
        /// (`AGENTS.md`, `MEMORY.md`, `.env`) can reclassify a zero-byte
        /// read as `.absent`: zero bytes is damage for a JSON sidecar Scarf
        /// never writes empty, but an empty markdown or env file is a real,
        /// writable state a person made.
        public init(state: State, bytes: Data?, quarantineCopy: String? = nil) {
            self.state = state
            self.bytes = bytes
            self.quarantineCopy = quarantineCopy
        }

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

    // MARK: - Existence

    /// What an existence probe could PROVE about a path.
    public enum Existence: Sendable, Equatable {
        /// Two independent probes agreed there is nothing there.
        case provenAbsent
        /// Something is there, or we could not prove otherwise.
        case present
    }

    /// "Is it safe to create this file?" answered with proof rather than one
    /// `fileExists` (GW-E2c).
    ///
    /// The create-if-missing gate — `if !transport.fileExists(p) { write }` —
    /// looks innocent and is the same inference bug as `try? read ?? []`
    /// wearing a different hat: over SSH `fileExists` is a round trip, one
    /// dropped round trip answers `false`, and the scaffold placeholder then
    /// lands on top of the real, agent-authored file. Two independent probes
    /// have to agree before we will call a path empty — cheap, because the
    /// present path still answers on the FIRST probe and pays nothing.
    ///
    /// Deliberately does not read the file: callers of this helper are
    /// deciding whether to CREATE, and pulling an unknown number of bytes
    /// across a transport to answer a yes/no question is the wrong trade.
    /// Callers that need the contents use `inspect` instead.
    public nonisolated static func probeExistence(
        _ path: String, transport: any ServerTransport
    ) -> Existence {
        if transport.fileExists(path) { return .present }
        if transport.stat(path) != nil { return .present }
        return .provenAbsent
    }

    // MARK: - Read

    /// One read answering every question a guarded write has to ask: is
    /// this damage, what should the `.bak` capture, and what should the
    /// decoder see. Reading per question would be one SSH/SFTP round-trip
    /// per question.
    ///
    /// - Parameter maxBytes: anything larger is REFUSED — and refused
    ///   without being read.
    ///
    /// **The cap is enforced by a `stat`, BEFORE the read** (GW-F5 / SEC F3).
    /// It used to be enforced after: the whole file was pulled into memory
    /// and then measured, which made the cap a statement about what we would
    /// DECODE rather than about what we would HOLD — a multi-gigabyte
    /// `MEMORY.md` still landed in RAM on an iPhone before being declared too
    /// big, and quarantining it then doubled the residency.
    ///
    /// **The cost, and why it is paid.** A capped inspection is now
    /// `stat` + `read` instead of `read`, i.e. one extra SSH/SFTP round-trip
    /// on every healthy remote load. That is deliberate: the stat is free
    /// locally, it is one round-trip on remote paths that already pay one to
    /// three, and it is the only ordering in which the phone — which is
    /// remote-ONLY, so a local-only rule would protect nobody — can refuse a
    /// runaway file instead of being jetsammed by it. Callers that genuinely
    /// want no bound pass `Int.max` and pay nothing: the probe is skipped
    /// entirely for them, which keeps the uncapped loads at exactly ONE read.
    ///
    /// **An over-cap file is `.unreadable`, not `.quarantined`,** and there is
    /// no `.corrupt-` copy of it: we never held its bytes, so there is
    /// nothing to copy aside and nothing to rebuild from. Both damage
    /// policies therefore refuse on size — a `.quarantineAndRebuild` store
    /// freezes rather than replacing a file it never saw (the audit's
    /// accepted availability-for-integrity trade). The bytes are untouched
    /// where they are; a human raising the cap or trimming the file is the
    /// way out.
    ///
    /// Verdicts are otherwise unchanged: the probe only fires when a `stat`
    /// SUCCEEDS and reports a size past the cap, so a transport that cannot
    /// stat falls through to the exact read-then-probe correlation below and
    /// its `.absent` / `.unreadable` answers are the same as before.
    public nonisolated func inspect(_ path: String, maxBytes: Int) -> Inspection {
        if maxBytes != Int.max, let info = transport.stat(path), info.size > Int64(maxBytes) {
            #if canImport(os)
            Self.logger.error(
                "\(self.label, privacy: .public) at \(path, privacy: .public) is \(info.size) bytes (cap \(maxBytes)); refusing without reading it"
            )
            #endif
            return Inspection(state: .unreadable(path: path), bytes: nil)
        }
        var read: Data?
        do {
            read = try transport.readFile(path)
        } catch let error as TransportError where error.isNoSuchFile {
            // POSITIVE proof of absence from the far end (GW-F6 / audit DI
            // L1) — and one round-trip cheaper than proving it by double
            // negative. Everything else still falls through to the probe.
            return Inspection(state: .absent, bytes: nil)
        } catch {
            read = nil
        }
        if read == nil {
            guard let info = transport.stat(path) else {
                // Absence by DOUBLE NEGATIVE: a read that failed for a
                // reason other than ENOENT, and a stat that could not
                // confirm the file either. Over ONE SSH channel those two
                // failures are correlated, so this is the residual the
                // ENOENT branch above shrinks but cannot remove — a
                // transport that reports neither ENOENT nor a stat leaves
                // nothing better to infer from. Callers deciding whether to
                // CREATE take `probeExistence` on top of this.
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
            // Fallback for a transport that could not `stat` (the probe
            // above is what normally catches this). Same verdict, so the
            // cap means one thing whichever branch enforces it: refuse,
            // and do NOT write a `.corrupt-` copy — quarantining an
            // oversized file is precisely the residency-doubling the cap
            // exists to prevent.
            #if canImport(os)
            Self.logger.error(
                "\(self.label, privacy: .public) at \(path, privacy: .public) is \(data.count) bytes (cap \(maxBytes)); refusing"
            )
            #endif
            return Inspection(state: .unreadable(path: path), bytes: nil)
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

        // A QUARANTINED PREDECESSOR IS NOT A BACKUP (P8 DI-M2). The `.bak`
        // is one-deep and holds the last version of this file we believe
        // was good. Refreshing it with bytes we just declared unusable
        // destroys that — and buys nothing, because those exact bytes are
        // already saved in the `.corrupt-<stamp>` copy the quarantine made.
        // Corruption then costs the user both copies: the live file
        // (rebuilt from empty, correctly) and the last good one.
        var keepsBackup = true
        if case .quarantined = inspection.state { keepsBackup = false }

        if keepsBackup, let existing = inspection.bytes, !existing.isEmpty, existing != data {
            // Best effort: losing the backup is not a reason to fail the
            // write the user asked for.
            do {
                // UNGUARDED-WRITE(G): GuardedJSONStore's own .bak publish.
                try transport.unguardedWriteFile(path + ".bak", data: existing)
            } catch {
                #if canImport(os)
                Self.logger.warning(
                    "Could not refresh \(self.label, privacy: .public).bak: \(error.localizedDescription, privacy: .public)"
                )
                #endif
            }
        }
        // UNGUARDED-WRITE(G): GuardedJSONStore's own guarded publish.
        try transport.unguardedWriteFile(path, data: data)
    }

    // MARK: - Quarantine

    private nonisolated func quarantining(data: Data, path: String) -> Inspection {
        if let copy = Self.quarantine(data: data, path: path, transport: transport, label: label) {
            return Inspection(state: .quarantined(copy: copy), bytes: data, quarantineCopy: copy)
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
            // UNGUARDED-WRITE(G): GuardedJSONStore's own quarantine copy.
            try transport.unguardedWriteFile(destination, data: data)
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

    /// A publish was attempted with no inspection behind it — the store
    /// never read the file, or dropped what it read. Validating against
    /// nothing is the destroy shape; see `GuardedSidecarStore.publish`.
    case refusedUninspectedWrite(path: String, label: String)

    public var errorDescription: String? {
        switch self {
        case let .refusedUnreadableOverwrite(path, label):
            return "\(label) at \(path) exists but couldn't be read; refusing to overwrite it."
        case let .refusedUninspectedWrite(path, label):
            return "\(label) at \(path) wasn't read before this save; refusing to overwrite it."
        }
    }
}
