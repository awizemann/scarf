import Foundation

// MARK: - Salvage reporting

/// What a salvaging registry decode had to repair.
///
/// `~/.hermes/scarf/projects.json` is agent-writable by design, so a
/// bad row is a routine event, not an exceptional one: on 2026-09-02 an
/// agent wrote `"uuid": "SHABUBOX-SEO-TRACKER-2026-09-03"` and the
/// strict decode emptied every project surface in the app. Decoding now
/// keeps what it can and reports the damage here so a caller can say so.
public struct RegistrySalvageReport: Sendable, Equatable {
    /// Rows that could not be decoded at all and were skipped.
    public var droppedCount: Int
    /// Every optional field that held an undecodable value and was
    /// dropped, the row surviving without it. Structured rather than
    /// pre-joined so the doctor can attach a finding to the ROW it
    /// belongs to: a project name may legally contain a `.`, which makes
    /// splitting `"<row>.<field>"` back apart a guess.
    public var salvaged: [SalvagedField]

    public static let clean = RegistrySalvageReport(droppedCount: 0, salvaged: [])

    public init(droppedCount: Int = 0, salvaged: [SalvagedField] = []) {
        self.droppedCount = droppedCount
        self.salvaged = salvaged
    }

    /// `"<project name>.<field>"` per dropped field — the flattened form
    /// the Phase-2 banner's dismissal signature is built from.
    public var salvagedFields: [String] { salvaged.map(\.description) }

    public var isClean: Bool { droppedCount == 0 && salvaged.isEmpty }
}

/// One optional field dropped from a surviving registry row.
public struct SalvagedField: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The row's display name (the registry's identity key).
    public let row: String
    /// The JSON key whose value could not be read (`uuid`, `folder`, `archived`).
    public let field: String

    public init(row: String, field: String) {
        self.row = row
        self.field = field
    }

    public var description: String { "\(row).\(field)" }
}

/// Collector threaded through `JSONDecoder.userInfo` so a salvaging
/// decode can report what it repaired. A reference type by necessity —
/// `Decodable.init(from:)` has no other return channel. Locked because
/// the same decoder could in principle be shared; a decode itself is
/// synchronous and single-threaded, so the lock is never contended.
public final class RegistrySalvageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var droppedCount = 0
    private var salvaged: [SalvagedField] = []

    public init() {}

    public func recordDroppedRow() {
        lock.lock()
        droppedCount += 1
        lock.unlock()
    }

    public func recordSalvagedField(_ field: String, row: String) {
        lock.lock()
        salvaged.append(SalvagedField(row: row, field: field))
        lock.unlock()
    }

    public var report: RegistrySalvageReport {
        lock.lock()
        defer { lock.unlock() }
        return RegistrySalvageReport(droppedCount: droppedCount, salvaged: salvaged)
    }
}

// MARK: - The one definition of "lossy"

/// Damage that makes rewriting `projects.json` DESTRUCTIVE, and therefore
/// blocks every registry write.
///
/// **This enum is the single definition of "lossy" in the app.** It used
/// to be spelled three different ways — `ProjectsViewModel` refused any
/// salvage at all, the doctor and the MCP tools refused only row loss —
/// so the same broken file blocked a rename while allowing a repair.
/// Everything now asks `RegistryLoadResult.loss`, and the chokepoint
/// (`ProjectDashboardService.saveRegistry`) enforces it, so a caller
/// cannot forget.
///
/// The rule: **losing whole ROWS blocks; losing a FIELD does not.** A
/// dropped row exists only in the file — rewriting deletes a project for
/// good. A dropped field held a value nothing could read; writing without
/// it is what the uuid repairs are FOR. Field damage is still not
/// invisible: `ProjectDoctorService` raises a finding per row so the user
/// can see (and restore) what was skipped.
public enum RegistryLoss: Sendable, Equatable {
    /// The decode skipped whole rows; those projects exist only in the
    /// file on disk, which is why the path travels with the count — every
    /// message about this damage has to say which file to go and fix.
    case rowsDropped(count: Int, path: String)
    /// The file could not be parsed as a registry at all and was copied
    /// aside to `path`.
    case quarantined(path: String)
    /// The file EXISTS but yielded no usable bytes — zero-length, or a
    /// read that failed. Indistinguishable from a healthy empty registry
    /// once decoded, which is exactly why it has to be named: treating it
    /// as "no projects yet" let the next save persist that emptiness.
    case unreadable(path: String)

    /// One plain sentence, phrased for a user who did not write this file.
    public var message: String {
        switch self {
        case let .rowsDropped(n, path):
            return "\(n) \(n == 1 ? "project" : "projects") in \(path) couldn't be read. Changes are paused so saving doesn't drop \(n == 1 ? "it" : "them") permanently — fix or restore the file first."
        case .quarantined(let path):
            return "Your projects file couldn't be read at all and was set aside at \(path). Changes are paused until it's restored — repair the file, or delete it to start a fresh list."
        case .unreadable(let path):
            return "Your projects file at \(path) is empty or couldn't be read. Changes are paused because Scarf can't tell an empty list from a file it failed to read — restore it from the backup beside it, or delete it to start a fresh list."
        }
    }
}

/// Registry write refusals. Distinct from `TransportError` so callers
/// can tell "the disk said no" from "we refused to do this".
public enum ProjectRegistryError: LocalizedError, Sendable, Equatable {
    /// Refused to persist an empty project list over a file that still
    /// holds projects. `existingCount` is `nil` when the existing file was
    /// unparseable — unreachable since the lossy refusal below runs first
    /// and covers that case, but kept so the error's shape is stable.
    case refusedEmptyOverwrite(path: String, existingCount: Int?)
    /// Refused to write over a registry whose last read LOST something —
    /// the chokepoint guard. Thrown by `ProjectDashboardService.saveRegistry`
    /// and by `ProjectStore.indexInRegistry` before it appends anything.
    case refusedLossyOverwrite(path: String, loss: RegistryLoss)
    /// Another process (the `scarf-projects` MCP helper, a second Scarf
    /// window) held the registry write lock past the wait budget. The write
    /// did NOT happen — see `RegistryWriteLock`. A failure the caller can
    /// report and the user can retry, rather than a clobber nobody sees.
    case registryBusy(path: String)
    /// The file changed between the read this mutation was computed from
    /// and the write. Somebody else — a second Scarf window on another
    /// machine sharing the home, the MCP helper, an agent's editor — got
    /// there first, and this write would erase their change.
    ///
    /// Same-machine writers are serialised by `RegistryWriteLock`; this
    /// catches what a lock cannot: a REMOTE registry, where the read and
    /// the write are seconds apart over SSH and the lock is local only.
    case refusedStaleOverwrite(path: String)

    public var errorDescription: String? {
        switch self {
        case let .refusedEmptyOverwrite(path, existingCount):
            let existing = existingCount.map { "\($0) project(s)" } ?? "unreadable content"
            return "Refused to overwrite \(path) (\(existing)) with an empty project list."
        case let .refusedLossyOverwrite(_, loss):
            return loss.message
        case .registryBusy(let path):
            return "Another Scarf process is updating \(path) right now. Nothing was changed — try again in a moment."
        case .refusedStaleOverwrite(let path):
            return "\(path) was changed by something else while this was open. Nothing was changed — reopen the list and try again."
        }
    }
}

public extension CodingUserInfoKey {
    /// Key under which a `RegistrySalvageLog` is passed to a decoder.
    /// Absent = salvage still happens, it just isn't reported.
    static let projectRegistrySalvage = CodingUserInfoKey(rawValue: "com.scarf.projectRegistrySalvage")!
}

public extension ProjectRegistry {
    /// Decode a registry, salvaging what it can: a row with an invalid
    /// optional field keeps the row (minus the field), a wholly
    /// undecodable row is skipped, and only a file that isn't a
    /// registry at all throws.
    static func decodeSalvaging(from data: Data) throws -> (registry: ProjectRegistry, salvage: RegistrySalvageReport) {
        let log = RegistrySalvageLog()
        let decoder = JSONDecoder()
        decoder.userInfo[.projectRegistrySalvage] = log
        let registry = try decoder.decode(ProjectRegistry.self, from: data)
        return (registry, log.report)
    }
}
