import Foundation
#if canImport(os)
import os
#endif

/// Tracks "what skills did this Scarf instance see last time on this
/// server" so the Skills tab can render a "2 new, 4 updated since you
/// last looked" pill — same pattern Hermes's `hermes skills update`
/// shows in the CLI.
///
/// **Storage shape.** Per server. Mac persists to a JSON file under
/// `~/Library/Application Support/com.scarf/skill-snapshots/<serverID>.json`;
/// iOS persists to `UserDefaults` under
/// `com.scarf.ios.skill-snapshot.<serverID>`. Both stores hold a
/// `[skillId: SkillSignature]` map. `skillId` is `<category>/<name>`
/// from the loader; `SkillSignature` is a compact hash of file count
/// + sorted file names so a skill update (added/removed/renamed file)
/// shows up as a delta even if Hermes-version-pinning isn't in play.
///
/// **Failure model.** Persist errors log + no-op (the diff degrades
/// to "everything looks new" but the user can still mark seen). Read
/// errors return an empty snapshot so the diff treats every skill as
/// new — annoying once but recoverable.
public struct SkillSnapshotService: Sendable {
    #if canImport(os)
    static let logger = Logger(
        subsystem: "com.scarf",
        category: "SkillSnapshotService"
    )
    #endif

    public let serverID: ServerID
    private let backend: SnapshotBackend

    public init(serverID: ServerID) {
        self.serverID = serverID
        #if os(macOS)
        self.backend = .file(MacSnapshotBackend())
        #else
        self.backend = .userDefaults(IOSSnapshotBackend())
        #endif
    }

    /// Public for tests. Production callers use the no-arg
    /// init that picks the right backend per platform.
    public init(serverID: ServerID, backend: SnapshotBackend) {
        self.serverID = serverID
        self.backend = backend
    }

    // MARK: - Public API

    /// Compute the delta between the current skill set and the
    /// last snapshot. Returns counts only — the caller renders them
    /// in a pill ("2 new, 4 updated since you last looked").
    public func diff(against current: [HermesSkill]) -> SkillSnapshotDiff {
        let last = backend.read(for: serverID)
        let currentSigs = Self.signatures(for: current)

        var newCount = 0
        var updatedCount = 0
        for (id, sig) in currentSigs {
            if let prev = last[id] {
                if prev != sig { updatedCount += 1 }
            } else {
                newCount += 1
            }
        }
        return SkillSnapshotDiff(
            newCount: newCount,
            updatedCount: updatedCount,
            previousSnapshotEmpty: last.isEmpty,
            changedSkillIds: Set(currentSigs.compactMap { id, sig in
                let prev = last[id]
                if prev == nil { return id }
                return prev != sig ? id : nil
            })
        )
    }

    /// Record the current skills as seen. Called on user action
    /// ("Mark all as seen") or on the first-ever load (when
    /// `previousSnapshotEmpty` is true and we don't want to show
    /// every skill as new on next launch).
    public func markSeen(_ current: [HermesSkill]) {
        backend.write(Self.signatures(for: current), for: serverID)
    }

    // MARK: - Private

    /// Compute a stable per-skill signature: `<fileCount>:<joined-files>`.
    /// Hash via Foundation's `String.hashValue` would be unstable
    /// across launches, so we keep the raw concatenation; payload is
    /// small enough that storage size doesn't matter.
    static func signatures(for skills: [HermesSkill]) -> [String: SkillSignature] {
        var result: [String: SkillSignature] = [:]
        for skill in skills {
            let files = skill.files.sorted().joined(separator: "|")
            result[skill.id] = "\(skill.files.count):\(files)"
        }
        return result
    }
}

public typealias SkillSignature = String

/// Result of comparing the current skills to the last snapshot.
public struct SkillSnapshotDiff: Sendable, Equatable {
    public let newCount: Int
    public let updatedCount: Int
    /// True when this is the first time we've ever seen the skills
    /// for this server (no prior snapshot on disk). The view should
    /// silently mark everything as seen rather than rendering a
    /// "5 new!" pill on a fresh install.
    public let previousSnapshotEmpty: Bool
    /// Skill ids (`<category>/<name>`) that count as new or updated.
    /// Used by the Mac UI to filter the tree to only changed entries
    /// when the user taps the pill.
    public let changedSkillIds: Set<String>

    public var hasChanges: Bool { newCount + updatedCount > 0 }

    public init(
        newCount: Int,
        updatedCount: Int,
        previousSnapshotEmpty: Bool,
        changedSkillIds: Set<String>
    ) {
        self.newCount = newCount
        self.updatedCount = updatedCount
        self.previousSnapshotEmpty = previousSnapshotEmpty
        self.changedSkillIds = changedSkillIds
    }

    /// Compact label for the "What's New" pill, e.g.
    /// "2 new, 4 updated since you last looked" or "1 new skill".
    public var label: String {
        switch (newCount, updatedCount) {
        case (let n, 0): return n == 1 ? "1 new skill since you last looked" : "\(n) new skills since you last looked"
        case (0, let u): return u == 1 ? "1 updated skill since you last looked" : "\(u) updated skills since you last looked"
        default: return "\(newCount) new, \(updatedCount) updated since you last looked"
        }
    }
}

// MARK: - Backend abstraction

/// Per-platform persistence for the skill-snapshot store. Both
/// implementations encode `[skillId: signature]` as JSON and key by
/// `ServerID`. Tests use the in-memory variant.
public enum SnapshotBackend: Sendable {
    case file(MacSnapshotBackend)
    case userDefaults(IOSSnapshotBackend)
    case inMemory(InMemorySnapshotBackend)

    func read(for serverID: ServerID) -> [String: SkillSignature] {
        switch self {
        case .file(let b): return b.read(for: serverID)
        case .userDefaults(let b): return b.read(for: serverID)
        case .inMemory(let b): return b.read(for: serverID)
        }
    }

    func write(_ snapshot: [String: SkillSignature], for serverID: ServerID) {
        switch self {
        case .file(let b): b.write(snapshot, for: serverID)
        case .userDefaults(let b): b.write(snapshot, for: serverID)
        case .inMemory(let b): b.write(snapshot, for: serverID)
        }
    }
}

#if os(macOS)
/// Mac persistence: one JSON file per server under
/// `~/Library/Application Support/com.scarf/skill-snapshots/`.
public struct MacSnapshotBackend: Sendable {
    public init() {}

    public func read(for serverID: ServerID) -> [String: SkillSignature] {
        guard let url = Self.fileURL(for: serverID),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: SkillSignature].self, from: data)
        else { return [:] }
        return map
    }

    public func write(_ snapshot: [String: SkillSignature], for serverID: ServerID) {
        guard let url = Self.fileURL(for: serverID) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            #if canImport(os)
            SkillSnapshotService.logger.warning(
                "couldn't persist skill snapshot for \(serverID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            #endif
        }
    }

    private static func fileURL(for serverID: ServerID) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("com.scarf", isDirectory: true)
            .appendingPathComponent("skill-snapshots", isDirectory: true)
            .appendingPathComponent("\(serverID.uuidString).json")
    }
}
#else
public struct MacSnapshotBackend: Sendable {
    public init() {}
    public func read(for serverID: ServerID) -> [String: SkillSignature] { [:] }
    public func write(_ snapshot: [String: SkillSignature], for serverID: ServerID) {}
}
#endif

/// iOS persistence: one UserDefaults key per server.
/// `@unchecked Sendable` because `UserDefaults` itself doesn't conform
/// — it is in fact thread-safe per Apple docs, the conformance just
/// hasn't been added to the headers.
public final class IOSSnapshotBackend: @unchecked Sendable {
    public static let keyPrefix = "com.scarf.ios.skill-snapshot."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read(for serverID: ServerID) -> [String: SkillSignature] {
        let key = Self.keyPrefix + serverID.uuidString
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: SkillSignature].self, from: data)
        else { return [:] }
        return map
    }

    public func write(_ snapshot: [String: SkillSignature], for serverID: ServerID) {
        let key = Self.keyPrefix + serverID.uuidString
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory backend for tests. Per-instance map; not shared.
public final class InMemorySnapshotBackend: @unchecked Sendable {
    private var store: [ServerID: [String: SkillSignature]] = [:]

    public init() {}

    public func read(for serverID: ServerID) -> [String: SkillSignature] {
        store[serverID] ?? [:]
    }

    public func write(_ snapshot: [String: SkillSignature], for serverID: ServerID) {
        store[serverID] = snapshot
    }
}
