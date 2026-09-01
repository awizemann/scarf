#if canImport(SQLite3)

import Testing
import Foundation
@testable import ScarfCore

/// Coverage for `RemoteSQLiteBackend.parsePreflightOutput` — the capability
/// derivation that decides which Hermes-parity SQL the remote backend is
/// allowed to emit (v0.20.4 `hidden` / `last_read_at` / listable-child
/// support, including the SQLite-3.37 no-JSON1 fallback that forces the
/// session list back to roots-only).
///
/// The derivation had zero tests: a wrong `hasListableChildSupport` on an
/// older remote means a `no such function: json_extract` error that empties
/// the whole session list, and a wrong `hasLastReadAtColumn` means either a
/// missing-column SQL error or a permanently un-badged sidebar.
///
/// Driven with canned preflight stdout in the exact shape the remote
/// produces — `sqlite3 --version` line, then one `-json` array per
/// statement (`PRAGMA table_info(sessions)`, `PRAGMA table_info(messages)`,
/// `SELECT COUNT(*) ... session_model_usage`).
@Suite("RemoteSQLiteBackend preflight derivation")
struct RemoteSQLiteBackendPreflightTests {

    // MARK: - Fixture builders

    private static func tableInfo(_ columns: [String]) -> String {
        let rows = columns.enumerated().map { idx, name in
            "{\"cid\":\(idx),\"name\":\"\(name)\",\"type\":\"TEXT\",\"notnull\":0,\"dflt_value\":null,\"pk\":0}"
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    /// Every `sessions` column a fully-migrated v0.20.4 host has, as far as
    /// this derivation cares.
    private static let v0204SessionColumns = [
        "id", "source", "started_at", "ended_at", "end_reason", "session_key",
        "model_config", "reasoning_tokens", "api_call_count", "rewind_count",
        "pinned", "last_activity_at", "last_activity_description",
        "hidden", "last_read_at",
    ]
    private static let v0204MessageColumns = [
        "id", "session_id", "timestamp", "reasoning_content", "active", "compacted",
    ]

    private static func preflight(
        version: String = "3.45.1 2024-01-30 16:01:20",
        sessions: [String] = v0204SessionColumns,
        messages: [String] = v0204MessageColumns,
        usageTableCount: Int? = 1
    ) -> String {
        var out = version + "\n" + tableInfo(sessions) + "\n" + tableInfo(messages)
        if let usageTableCount {
            out += "\n[{\"n\":\(usageTableCount)}]"
        }
        return out
    }

    private static func backend() -> RemoteSQLiteBackend {
        RemoteSQLiteBackend(
            context: .local,
            transport: LocalTransport(contextID: ServerContext.local.id)
        )
    }

    // MARK: - Fully-migrated host

    @Test func fullV0204HostEnablesEveryProbe() async throws {
        let backend = Self.backend()
        try await backend.parsePreflightOutput(Self.preflight())
        #expect(await backend.hasHiddenColumn)
        #expect(await backend.hasLastReadAtColumn)
        #expect(await backend.hasListableChildSupport)
        #expect(await backend.hasSessionActivityColumns)
        #expect(await backend.hasSessionModelUsageTable)
        #expect(await backend.hasV07Schema)
        #expect(await backend.hasV011Schema)
        #expect(await backend.hasRewindCountColumn)
        #expect(await backend.hasMessagesActiveColumn)
        #expect(await backend.hasCompactedColumn)
        // v0.21 `_compressed_summary` is absent from the v0.20.4
        // fixture — detection must stay false rather than ride along
        // with `compacted`.
        #expect(await backend.hasCompressedSummaryColumn == false)
    }

    /// v0.21 `messages._compressed_summary`, derived on its own. Scarf
    /// emits no SQL that references it (see `SessionPreviewSQL`), but the
    /// flag must still track the host truthfully — `SCHEMA_VERSION` stayed
    /// at 26 across this DDL change, so presence is the only sound gate.
    @Test func compressedSummaryColumnIsDerivedIndependently() async throws {
        let v021 = Self.backend()
        try await v021.parsePreflightOutput(
            Self.preflight(messages: Self.v0204MessageColumns + ["_compressed_summary"])
        )
        #expect(await v021.hasCompressedSummaryColumn)
        #expect(await v021.hasCompactedColumn)

        // A host with the marker column but no `compacted` (hypothetical
        // partial migration) must not have the two flags bleed together.
        let markerOnly = Self.backend()
        try await markerOnly.parsePreflightOutput(
            Self.preflight(
                messages: Self.v0204MessageColumns.filter { $0 != "compacted" } + ["_compressed_summary"]
            )
        )
        #expect(await markerOnly.hasCompressedSummaryColumn)
        #expect(await markerOnly.hasCompactedColumn == false)
    }

    // MARK: - The v0.20.4 marker columns

    @Test func hiddenAndLastReadAtAreDerivedIndependently() async throws {
        let onlyHidden = Self.backend()
        try await onlyHidden.parsePreflightOutput(
            Self.preflight(sessions: Self.v0204SessionColumns.filter { $0 != "last_read_at" })
        )
        #expect(await onlyHidden.hasHiddenColumn)
        #expect(await onlyHidden.hasLastReadAtColumn == false)
        // A half-migrated host must NOT get the listable-child SQL.
        #expect(await onlyHidden.hasListableChildSupport == false)

        let onlyLastRead = Self.backend()
        try await onlyLastRead.parsePreflightOutput(
            Self.preflight(sessions: Self.v0204SessionColumns.filter { $0 != "hidden" })
        )
        #expect(await onlyLastRead.hasHiddenColumn == false)
        #expect(await onlyLastRead.hasLastReadAtColumn)
        #expect(await onlyLastRead.hasListableChildSupport == false)
    }

    @Test func preV0204HostHasNeitherMarkerNorChildSupport() async throws {
        let backend = Self.backend()
        try await backend.parsePreflightOutput(
            Self.preflight(sessions: Self.v0204SessionColumns.filter {
                $0 != "hidden" && $0 != "last_read_at"
            })
        )
        #expect(await backend.hasHiddenColumn == false)
        #expect(await backend.hasLastReadAtColumn == false)
        #expect(await backend.hasListableChildSupport == false)
    }

    // MARK: - Predicate columns the listable-child SQL reads

    @Test func missingAnyPredicateColumnDisablesChildSupport() async throws {
        for missing in ["model_config", "session_key", "end_reason", "started_at", "ended_at"] {
            let backend = Self.backend()
            try await backend.parsePreflightOutput(
                Self.preflight(sessions: Self.v0204SessionColumns.filter { $0 != missing })
            )
            // The marker columns are still there …
            #expect(await backend.hasHiddenColumn)
            #expect(await backend.hasLastReadAtColumn)
            // … but the predicate would reference a column that doesn't
            // exist, so the backend must fall back to roots-only.
            #expect(await backend.hasListableChildSupport == false, "missing \(missing)")
        }
    }

    // MARK: - SQLite 3.37 (no JSON1) fallback

    @Test func sqlite337ForcesRootsOnlyDespiteFullSchema() async throws {
        let backend = Self.backend()
        try await backend.parsePreflightOutput(
            Self.preflight(version: "3.37.2 2022-01-06 13:25:41")
        )
        // The schema is fully v0.20.4 …
        #expect(await backend.hasHiddenColumn)
        #expect(await backend.hasLastReadAtColumn)
        // … but `json_extract` isn't compiled into the remote sqlite3, so
        // the listable-child predicate would blow up with "no such
        // function" and empty the session list. Roots-only instead.
        #expect(await backend.hasListableChildSupport == false)
    }

    @Test func json1AvailabilityBoundaryIs338() {
        // JSON1 is built in from 3.38.0 onward.
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3.38.0 2022-02-22 18:58:40") == true)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3.37.9 2022-01-06 13:25:41") == false)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3.45.1 2024-01-30 16:01:20") == true)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "4.0.0 2030-01-01") == true)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "2.8.17 2005-01-01") == false)
        // Unparseable / absent → treated as "no JSON1", the safe side:
        // a roots-only list beats an errored, empty one.
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: nil) == false)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "") == false)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "sqlite3: not found") == false)
        #expect(RemoteSQLiteBackend.sqliteHasJSON1(versionLine: "3") == false)
    }

    // MARK: - Other derived flags

    @Test func v011NeedsBothTablesMigrated() async throws {
        // `api_call_count` on sessions but no `reasoning_content` on
        // messages = partial migration; the belt-and-braces AND must
        // reject it rather than emit SQL for a column that isn't there.
        let sessionsOnly = Self.backend()
        try await sessionsOnly.parsePreflightOutput(
            Self.preflight(messages: Self.v0204MessageColumns.filter { $0 != "reasoning_content" })
        )
        #expect(await sessionsOnly.hasV011Schema == false)

        let messagesOnly = Self.backend()
        try await messagesOnly.parsePreflightOutput(
            Self.preflight(sessions: Self.v0204SessionColumns.filter { $0 != "api_call_count" })
        )
        #expect(await messagesOnly.hasV011Schema == false)
    }

    @Test func sessionActivityColumnsRequireAllThree() async throws {
        for missing in ["pinned", "last_activity_at", "last_activity_description"] {
            let backend = Self.backend()
            try await backend.parsePreflightOutput(
                Self.preflight(sessions: Self.v0204SessionColumns.filter { $0 != missing })
            )
            #expect(await backend.hasSessionActivityColumns == false, "missing \(missing)")
        }
    }

    @Test func modelUsageTableFlagFollowsTheCountRow() async throws {
        let present = Self.backend()
        try await present.parsePreflightOutput(Self.preflight(usageTableCount: 1))
        #expect(await present.hasSessionModelUsageTable)

        let absent = Self.backend()
        try await absent.parsePreflightOutput(Self.preflight(usageTableCount: 0))
        #expect(await absent.hasSessionModelUsageTable == false)

        // Older two-array preflight shapes (cached transports, fixtures)
        // must default to false rather than mis-parse the messages array.
        let twoArrays = Self.backend()
        try await twoArrays.parsePreflightOutput(Self.preflight(usageTableCount: nil))
        #expect(await twoArrays.hasSessionModelUsageTable == false)
        // …and the rest of the derivation still works on that shape.
        #expect(await twoArrays.hasListableChildSupport)
    }

    // MARK: - Malformed output

    @Test func malformedPreflightOutputThrows() async {
        // Empty stdout (sqlite3 missing entirely).
        await #expect(throws: (any Error).self) {
            try await Self.backend().parsePreflightOutput("")
        }
        // Version line but only one PRAGMA array — can't derive the
        // messages-table flags, so this must fail loudly rather than
        // silently report a pre-v0.11 host.
        await #expect(throws: (any Error).self) {
            try await Self.backend().parsePreflightOutput("3.45.1\n" + Self.tableInfo(["id"]))
        }
    }
}

#endif
