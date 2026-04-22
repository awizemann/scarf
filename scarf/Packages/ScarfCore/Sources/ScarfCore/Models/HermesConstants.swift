import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - SQLite Constants

#if canImport(SQLite3)
/// SQLITE_TRANSIENT tells SQLite to make its own copy of bound string data.
/// The C macro is defined as ((sqlite3_destructor_type)-1) which can't be imported directly into Swift.
///
/// Gated behind `canImport(SQLite3)` so this file compiles on Linux (where
/// SPM has no built-in `SQLite3` system module). Apple platforms — the only
/// runtime targets that actually execute this code — compile it unchanged.
public nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

// MARK: - Query Defaults

public enum QueryDefaults: Sendable {
    public nonisolated static let sessionLimit = 100
    public nonisolated static let messageSearchLimit = 50
    public nonisolated static let toolCallLimit = 50
    public nonisolated static let sessionPreviewLimit = 10
    public nonisolated static let previewContentLength = 100
    public nonisolated static let logLineLimit = 200
    public nonisolated static let defaultSilenceThreshold = 200
}

// MARK: - File Size Formatting

public enum FileSizeUnit: Sendable {
    public nonisolated static let kilobyte = 1_024.0
    public nonisolated static let megabyte = 1_048_576.0
}
