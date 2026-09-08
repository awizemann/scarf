import Testing
import Foundation
@testable import ScarfCore

/// GW-E3 — `GuardedSidecarStore`, the adoption path.
///
/// Only the parts the protocol ADDS are tested here: the per-file damage
/// policy, the `.quarantined → .unreadable` reclassification the default
/// implementation now owns for the decode failure (the size cap is refused
/// stat-first for every adopter since GW-F5), the preserved quarantine-copy
/// path, and the refusal of a
/// publish with no inspection behind it. Every migrated adopter's own
/// behavior is pinned by its existing, unedited suite.
///
/// Real temp directories through the real `LocalTransport`, W1 style.
@Suite struct GuardedSidecarStoreE3Tests {

    private struct Rebuildable: GuardedSidecarStore {
        static let label = "rebuildable.json"
        static let maxBytes = 64
        static let damagePolicy = GuardedDamagePolicy.quarantineAndRebuild
        let transport: any ServerTransport
    }

    private struct Irreplaceable: GuardedSidecarStore {
        static let label = "irreplaceable.json"
        static let maxBytes = 64
        static let damagePolicy = GuardedDamagePolicy.refuseForever
        let transport: any ServerTransport
    }

    private struct Row: Codable { var a: String }

    private static func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-e3-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Decode failure

    @Test func rebuildableQuarantinesAndStaysWritableOnUndecodableBytes() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("rebuildable.json").path
        let garbage = Data("{ not a row".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))

        let store = Rebuildable(transport: LocalTransport())
        let (inspection, value) = store.inspectDecoding(Row.self, at: path)
        #expect(value == nil)
        guard case .quarantined(let copy) = inspection.state else {
            Issue.record("expected .quarantined, got \(inspection.state)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == garbage)
        #expect(inspection.quarantineCopy == copy)

        // Writable: a rebuildable index rebuilds from empty.
        let fresh = Data(#"{"a":"rebuilt"}"#.utf8)
        try store.publish(fresh, to: path, after: inspection)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == fresh)
        // …and the quarantine cycle did NOT burn the one-deep .bak.
        #expect(!FileManager.default.fileExists(atPath: path + ".bak"))
    }

    @Test func refuseForeverReclassifiesUndecodableBytesToUnreadable() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("irreplaceable.json").path
        let garbage = Data("{ not a row".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))

        let store = Irreplaceable(transport: LocalTransport())
        let (inspection, value) = store.inspectDecoding(Row.self, at: path)
        #expect(value == nil)
        #expect(inspection.state == .unreadable(path: path))
        // THE COPY PATH SURVIVES THE RECLASSIFICATION: the write is refused,
        // but the user still has to be told where their bytes went.
        let copy = try #require(inspection.quarantineCopy)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == garbage)

        #expect(throws: GuardedStoreError.refusedUnreadableOverwrite(path: path, label: "irreplaceable.json")) {
            try store.publish(Data(#"{"a":"x"}"#.utf8), to: path, after: inspection)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == garbage)
    }

    // MARK: - Size cap (the branch a hand-rolled adopter forgets)

    /// SINCE GW-F5 THE SIZE CAP IS NOT A POLICY QUESTION. An oversized file
    /// is refused on a `stat`, before a single byte is read (SEC F3), so
    /// there are no bytes to copy aside and nothing to rebuild from — both
    /// policies refuse, and neither leaves a `.corrupt-` copy. The
    /// availability cost (a `.quarantineAndRebuild` store freezes instead of
    /// replacing a file it never saw) is the accepted side of that trade:
    /// the alternative is pulling a runaway file into memory on a phone to
    /// find out how big it is.
    @Test func refuseForeverRefusesTheSizeCapWithoutQuarantining() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("irreplaceable.json").path
        let huge = Data(String(repeating: "x", count: Irreplaceable.maxBytes + 1).utf8)
        try huge.write(to: URL(fileURLWithPath: path))

        let store = Irreplaceable(transport: LocalTransport())
        let inspection = store.inspect(path)
        #expect(inspection.state == .unreadable(path: path))
        #expect(inspection.bytes == nil)
        #expect(inspection.quarantineCopy == nil)
        #expect(throws: GuardedStoreError.self) {
            try store.publish(Data("{}".utf8), to: path, after: inspection)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == huge)
        let listed = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(!listed.contains { $0.contains(".corrupt-") })
    }

    @Test func rebuildableAlsoRefusesTheSizeCap() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("rebuildable.json").path
        let huge = Data(String(repeating: "x", count: Rebuildable.maxBytes + 1).utf8)
        try huge.write(to: URL(fileURLWithPath: path))

        let store = Rebuildable(transport: LocalTransport())
        let inspection = store.inspect(path)
        #expect(inspection.state == .unreadable(path: path))
        #expect(throws: GuardedStoreError.self) {
            try store.publish(Data("{}".utf8), to: path, after: inspection)
        }
        // The oversized bytes are untouched where they are — a human raising
        // the cap or trimming the file is the way out.
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == huge)
    }

    // MARK: - Policy-neutral states

    /// Neither policy touches a healthy file or a proven-absent one — the
    /// reclassification must not leak into the paths that are supposed to
    /// write.
    @Test func bothPoliciesWriteAnAbsentAndAHealthyFile() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("nested/irreplaceable.json").path

        let store = Irreplaceable(transport: LocalTransport())
        #expect(store.probeExistence(path) == .provenAbsent)
        let absent = store.inspect(path)
        #expect(absent.state == .absent)

        let first = Data(#"{"a":"one"}"#.utf8)
        try store.publish(first, to: path, after: absent)
        #expect(store.probeExistence(path) == .present)

        let (healthy, value) = store.inspectDecoding(Row.self, at: path)
        #expect(healthy.state == .present)
        #expect(value?.a == "one")
        let second = Data(#"{"a":"two"}"#.utf8)
        try store.publish(second, to: path, after: healthy)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == second)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + ".bak")) == first)
    }

    // MARK: - The held-inspection invariant

    /// A publish validates against the SAME inspection the in-memory state
    /// was built from — so a store that holds none has nothing to validate
    /// against and is refused, rather than silently treated as
    /// "proven absent" and allowed to publish over a live file.
    @Test func publishWithNoInspectionIsRefused() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("irreplaceable.json").path
        let existing = Data(#"{"a":"live"}"#.utf8)
        try existing.write(to: URL(fileURLWithPath: path))

        let store = Irreplaceable(transport: LocalTransport())
        #expect(throws: GuardedStoreError.refusedUninspectedWrite(path: path, label: "irreplaceable.json")) {
            try store.publish(Data(#"{"a":"clobber"}"#.utf8), to: path, after: nil)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == existing)
    }
}
