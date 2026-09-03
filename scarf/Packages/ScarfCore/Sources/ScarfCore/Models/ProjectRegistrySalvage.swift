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
    /// `"<project name>.<field>"` for every optional field that held an
    /// undecodable value and was dropped, the row surviving without it.
    public var salvagedFields: [String]

    public static let clean = RegistrySalvageReport(droppedCount: 0, salvagedFields: [])

    public init(droppedCount: Int = 0, salvagedFields: [String] = []) {
        self.droppedCount = droppedCount
        self.salvagedFields = salvagedFields
    }

    public var isClean: Bool { droppedCount == 0 && salvagedFields.isEmpty }
}

/// Collector threaded through `JSONDecoder.userInfo` so a salvaging
/// decode can report what it repaired. A reference type by necessity —
/// `Decodable.init(from:)` has no other return channel. Locked because
/// the same decoder could in principle be shared; a decode itself is
/// synchronous and single-threaded, so the lock is never contended.
public final class RegistrySalvageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var droppedCount = 0
    private var salvagedFields: [String] = []

    public init() {}

    public func recordDroppedRow() {
        lock.lock()
        droppedCount += 1
        lock.unlock()
    }

    public func recordSalvagedField(_ field: String, row: String) {
        lock.lock()
        salvagedFields.append("\(row).\(field)")
        lock.unlock()
    }

    public var report: RegistrySalvageReport {
        lock.lock()
        defer { lock.unlock() }
        return RegistrySalvageReport(droppedCount: droppedCount, salvagedFields: salvagedFields)
    }
}

/// Registry write refusals. Distinct from `TransportError` so callers
/// can tell "the disk said no" from "we refused to do this".
public enum ProjectRegistryError: LocalizedError, Sendable, Equatable {
    /// Refused to persist an empty project list over a file that still
    /// holds projects (or holds bytes we could not read).
    /// `existingCount` is `nil` when the existing file was unparseable.
    case refusedEmptyOverwrite(path: String, existingCount: Int?)

    public var errorDescription: String? {
        switch self {
        case let .refusedEmptyOverwrite(path, existingCount):
            let existing = existingCount.map { "\($0) project(s)" } ?? "unreadable content"
            return "Refused to overwrite \(path) (\(existing)) with an empty project list."
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
