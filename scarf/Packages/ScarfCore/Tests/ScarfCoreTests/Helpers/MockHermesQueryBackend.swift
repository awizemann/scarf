#if canImport(SQLite3)

import Foundation
@testable import ScarfCore

/// Test double for `HermesQueryBackend`. Lets the data-service-façade
/// tests assert which SQL gets emitted, with which params, and feed
/// scripted result rows back.
///
/// Implemented as an `actor` to satisfy the protocol's `Sendable`
/// requirement and to mirror how the real backends serialize state.
/// Marked `final` to prevent accidental subclassing — Swift Testing
/// instances are short-lived per-`@Test`, but a stray subclass could
/// hide override quirks.
final actor MockHermesQueryBackend: HermesQueryBackend {

    // MARK: - Knobs

    var openShouldSucceed: Bool = true
    var hasV07Schema: Bool = false
    var hasV011Schema: Bool = false
    var lastOpenError: String? = nil

    /// Map of SQL prefix → rows. Lookup picks the longest matching
    /// prefix, so callers can register both broad ("SELECT") and
    /// narrow ("SELECT id, source FROM sessions") matchers without
    /// the broad one swallowing the narrow one.
    private var scriptedResults: [String: [Row]] = [:]

    /// Map of SQL prefix → queued row pages. Lookup picks the longest
    /// matching prefix and consumes one page per query. Used when the same
    /// SQL shape is called repeatedly with different params (pagination).
    private var scriptedResultQueues: [String: [[Row]]] = [:]

    /// Map of SQL prefix → backend error to throw instead of returning
    /// rows. Used to test the data-service's error-swallowing paths.
    private var scriptedFailures: [String: BackendError] = [:]

    /// Every `query(_:params:)` call lands here in order — assertion
    /// material for "did the façade emit the SQL we expected".
    private(set) var queryLog: [(sql: String, params: [SQLValue])] = []

    /// Every `queryBatch` call lands here in order, one outer entry
    /// per call, inner entries for each statement in that batch.
    private(set) var batchLog: [[(sql: String, params: [SQLValue])]] = []

    /// Track open/refresh/close lifecycle for a couple of tests that
    /// want to assert "façade really did call open()".
    private(set) var openCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var closeCallCount = 0

    // MARK: - Knob mutators (called from tests)

    func setOpenShouldSucceed(_ value: Bool) { openShouldSucceed = value }
    func setHasV07Schema(_ value: Bool) { hasV07Schema = value }
    func setHasV011Schema(_ value: Bool) { hasV011Schema = value }
    func setLastOpenError(_ value: String?) { lastOpenError = value }

    /// Build a one-row result keyed on `prefix`. `columns` is the
    /// column-name → position map; `values` must be the same length.
    func _seedRow(forSQLPrefix prefix: String, columns: [String: Int], values: [SQLValue]) {
        let row = Row(values: values, columnIndex: columns)
        scriptedResults[prefix] = [row]
    }

    /// Seed an arbitrary row sequence for queries that share `prefix`.
    func _seedRows(forSQLPrefix prefix: String, _ rows: [Row]) {
        scriptedResults[prefix] = rows
    }

    /// Seed a sequence of row pages for repeated queries matching `prefix`.
    /// Each query consumes the next page; once exhausted, lookup falls back to
    /// the static rows map or returns empty.
    func _seedRowsSequence(forSQLPrefix prefix: String, _ pages: [[Row]]) {
        scriptedResultQueues[prefix] = pages
    }

    /// Make `query` throw the specified `error` whenever it sees a SQL
    /// that begins with `prefix`.
    func _seedFailure(forSQLPrefix prefix: String, error: BackendError) {
        scriptedFailures[prefix] = error
    }

    // MARK: - HermesQueryBackend conformance

    func open() async -> Bool {
        openCallCount += 1
        return openShouldSucceed
    }

    @discardableResult
    func refresh(forceFresh: Bool) async -> Bool {
        refreshCallCount += 1
        return openShouldSucceed
    }

    func close() async {
        closeCallCount += 1
    }

    func query(_ sql: String, params: [SQLValue]) async throws -> [Row] {
        queryLog.append((sql: sql, params: params))
        if let failure = longestMatchingFailure(for: sql) {
            throw failure
        }
        return longestMatchingRows(for: sql) ?? []
    }

    func queryBatch(_ statements: [(sql: String, params: [SQLValue])]) async throws -> [[Row]] {
        batchLog.append(statements)
        var out: [[Row]] = []
        out.reserveCapacity(statements.count)
        for stmt in statements {
            if let failure = longestMatchingFailure(for: stmt.sql) {
                throw failure
            }
            out.append(longestMatchingRows(for: stmt.sql) ?? [])
        }
        return out
    }

    // MARK: - Internals

    /// Pick the longest registered prefix that `sql` starts with.
    /// Ties go to whichever ordering Dictionary iteration produced —
    /// callers should not register two equal-length matchers for the
    /// same SQL because the resolution order is undefined.
    private func longestMatchingRows(for sql: String) -> [Row]? {
        if let queued = longestMatchingQueuedRows(for: sql) {
            return queued
        }
        var bestMatch: (key: String, rows: [Row])?
        for (prefix, rows) in scriptedResults {
            if sql.hasPrefix(prefix) {
                if let current = bestMatch {
                    if prefix.count > current.key.count {
                        bestMatch = (prefix, rows)
                    }
                } else {
                    bestMatch = (prefix, rows)
                }
            }
        }
        return bestMatch?.rows
    }

    private func longestMatchingQueuedRows(for sql: String) -> [Row]? {
        var bestKey: String?
        for (prefix, pages) in scriptedResultQueues {
            guard !pages.isEmpty, sql.hasPrefix(prefix) else { continue }
            if let current = bestKey {
                if prefix.count > current.count {
                    bestKey = prefix
                }
            } else {
                bestKey = prefix
            }
        }
        guard let bestKey else { return nil }
        var pages = scriptedResultQueues[bestKey] ?? []
        let rows = pages.removeFirst()
        scriptedResultQueues[bestKey] = pages
        return rows
    }

    private func longestMatchingFailure(for sql: String) -> BackendError? {
        var bestMatch: (key: String, error: BackendError)?
        for (prefix, error) in scriptedFailures {
            if sql.hasPrefix(prefix) {
                if let current = bestMatch {
                    if prefix.count > current.key.count {
                        bestMatch = (prefix, error)
                    }
                } else {
                    bestMatch = (prefix, error)
                }
            }
        }
        return bestMatch?.error
    }
}

#endif // canImport(SQLite3)
