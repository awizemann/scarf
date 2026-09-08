import Foundation
import ScarfCore
import os

/// Read/write `~/.hermes/.env` while preserving comments, blank lines, and the
/// ordering of keys we don't touch.
///
/// Hermes treats `.env` as a traditional dotenv file: `KEY=value`, `#` comments,
/// and optional double-quoted values for strings with spaces or special chars.
/// We do NOT attempt to implement full shell-style escaping; the fields we write
/// from the GUI are bot tokens, user IDs, URLs, and on/off flags — none of which
/// contain characters needing escaping beyond double-quoting.
///
/// Design choices:
/// - **Non-destructive "unset"**: clearing a field comments the line out rather
///   than deleting it, so users can restore a key by uncommenting without losing
///   their value.
/// - **Atomic write**: write to `.env.tmp`, then rename. Avoids a partially
///   written file if Scarf crashes mid-write.
/// - **Never logs values**: secrets flow through this service.
nonisolated struct HermesEnvService: Sendable {
    private let logger = Logger(subsystem: "com.scarf", category: "HermesEnvService")

    /// Path to `~/.hermes/.env`. Kept configurable for tests.
    let path: String
    let transport: any ServerTransport
    /// Carried so the guarded rewrite can take `.env`'s write lock (GW-F3).
    /// `nil` for the fixture-path initializer below, whose whole point is a
    /// throwaway file no second writer knows about.
    private let lockContext: ServerContext?

    nonisolated init(context: ServerContext = .local) {
        self.path = context.paths.envFile
        self.transport = context.makeTransport()
        self.lockContext = context
    }

    /// Escape hatch for tests that want to point at a fixture path directly.
    init(path: String) {
        self.path = path
        self.transport = LocalTransport()
        self.lockContext = nil
    }

    /// Read the .env file into a `[key: value]` dict. Comments and commented-out
    /// assignments are ignored. Missing file returns an empty dict.
    /// `nonisolated` so it can run off the main actor (it's pure transport I/O
    /// on a `Sendable` struct) — callers like `PlatformsViewModel.load()` read
    /// `.env` on a detached task to keep the main thread free (gh#102).
    nonisolated func load() -> [String: String] {
        (try? loadProven()) ?? [:]
    }

    /// Why a `.env` could not be read, when the caller needs to know the
    /// difference (GW-F6 / audit DI L10).
    enum LoadRefusal: LocalizedError, Equatable {
        case unreadable(path: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(path):
                return "Couldn't read \(path). It's there, but two reads of it failed — the fields below may be blank even though values are set. Fix the connection or the file's permissions before saving, or a save will comment those keys out."
            }
        }
    }

    /// ``load()`` with the two failures kept apart: an ABSENT `.env` is an
    /// empty dictionary (nothing is set yet, and an empty form is the
    /// truth), while a file that is provably there and unreadable THROWS.
    ///
    /// **Why the distinction is load-bearing.** `load() ?? [:]` is what feeds
    /// every platform setup form. A blip made it return `[:]`, the form
    /// rendered blank fields over live values, and `PlatformSetupHelpers`
    /// turns a blank field into an `unset` — so pressing Save on a form the
    /// user never edited commented out working API keys. The write itself
    /// was already safe (the guarded `unset` refuses while the file is
    /// unreadable); the hazard is the transient case where the read blips
    /// and the write a moment later succeeds. Surfacing at LOAD is what
    /// closes it, which is why the forms show the refusal instead of an
    /// empty form.
    nonisolated func loadProven() throws -> [String: String] {
        let loaded: GuardedTextFile.Loaded
        do {
            loaded = try GuardedTextFile(transport: transport, label: ".env").load(path)
        } catch {
            throw LoadRefusal.unreadable(path: path)
        }
        guard loaded.exists else { return [:] }
        let content = loaded.text
        var result: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip blanks and comments. A line beginning with `#` is either a pure
            // comment or a disabled assignment — both should be treated as "unset".
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let raw = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            result[key] = Self.stripEnvQuotes(raw)
        }
        return result
    }

    func get(_ key: String) -> String? {
        load()[key]
    }

    /// Write/update a single key. Preserves the position of existing assignments
    /// (even if they were commented out — the new assignment replaces the comment
    /// line in place). New keys are appended at the end.
    @discardableResult
    func set(_ key: String, value: String) -> Bool {
        setMany([key: value])
    }

    /// Update multiple keys in one atomic rewrite. Use this when a form saves
    /// several fields at once so the file doesn't get repeatedly rewritten.
    ///
    /// Returns `true` on success, `false` if the atomic rewrite failed.
    @discardableResult
    func setMany(_ pairs: [String: String]) -> Bool {
        // GUARDED AND SERIALIZED. This used to be `try? readFile … else header`, which
        // published a ONE-LINE `.env` — every API key Hermes owns, gone —
        // the first time a read blipped. `.env` is the highest-value
        // irreplaceable file Scarf writes: it refuses, it never rebuilds.
        // An EMPTY .env is a legal user state, so `exists` (not emptiness)
        // is what picks the header branch.
        //
        // The read is now taken INSIDE `.env`'s write lock and the publish
        // happens before it is released (GW-F3), so a concurrent
        // `KeychainEnvMirror` splice can no longer land between them and be
        // published away by this whole-file rewrite.
        return guardedMutate { loaded in
            var remaining = pairs
            var lines: [String]
            if loaded.exists {
                lines = loaded.text.components(separatedBy: "\n")
                // Trim a single trailing empty line from splitting the final newline;
                // we'll re-add it on write.
                if lines.last == "" { lines.removeLast() }
            } else {
                lines = ["# Hermes Agent Environment Configuration"]
            }

            // First pass: update in-place (handles both live and commented-out lines).
            for (idx, line) in lines.enumerated() {
                guard let match = Self.extractKey(fromLine: line) else { continue }
                if let newValue = remaining.removeValue(forKey: match.key) {
                    // A commented-out `# KEY=...` becomes a live `KEY=...` with the new value.
                    lines[idx] = Self.formatLine(key: match.key, value: newValue)
                }
            }

            // Second pass: append any keys that didn't match an existing line.
            if !remaining.isEmpty {
                // Leave a blank line before appending new keys for visual separation.
                if let last = lines.last, !last.isEmpty {
                    lines.append("")
                }
                for key in remaining.keys.sorted() {
                    lines.append(Self.formatLine(key: key, value: remaining[key]!))
                }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Comment out a key. The value is preserved so the user can restore by
    /// uncommenting. If the key doesn't exist, this is a no-op.
    @discardableResult
    func unset(_ key: String) -> Bool {
        // A refused load returns `false` here where the old `try?` returned
        // `true`: "we could not read it" is not "there was nothing to do".
        // Nothing-to-do (absent file, or no live assignment of `key`) returns
        // `nil` from the body, which publishes nothing and is still `true`.
        return guardedMutate { loaded in
            guard loaded.exists else { return nil }
            var lines = loaded.text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }

            var changed = false
            for (idx, line) in lines.enumerated() {
                guard let match = Self.extractKey(fromLine: line), match.key == key else { continue }
                // Skip lines that are already commented — nothing to do.
                if Self.isCommentedOutAssignment(line) { continue }
                lines[idx] = "# " + line
                changed = true
            }
            guard changed else { return nil }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    // MARK: - Internals

    /// SERIALIZED (GW-F3 / DI H4). `.env` has two in-app writers — this
    /// service and `KeychainEnvMirror` — plus the reconcile pass at launch,
    /// and every one of them is a whole-file read-modify-write. Interleaved,
    /// the loser's edit vanished AND the `.bak` was overwritten with the
    /// winner's pre-image, so the previous good copy was gone too. Both
    /// writers now go through `GuardedTextFile.mutate`, which is one lock
    /// hold from the read to the second of the two publishes.
    private var guardedFile: GuardedTextFile {
        if let lockContext {
            return GuardedTextFile(context: lockContext, label: ".env")
        }
        return GuardedTextFile(transport: transport, label: ".env")
    }

    /// One lock hold covering the proof-based read of `.env`, the caller's
    /// rewrite of it, and the publish (`.bak` + file).
    ///
    /// `false` means REFUSED or FAILED — the file is stat-confirmed but
    /// unreadable, holds non-UTF-8 bytes, another writer held the lock past
    /// its bound (`registryBusy`), or the publish itself failed. Every
    /// caller of `set`/`setMany`/`unset` already handles that `false`, which
    /// is why contention surfaces there rather than as a hang.
    ///
    /// Returning `nil` from `body` means "nothing to do": no publish, and
    /// still `true`.
    ///
    /// The publish keeps a one-deep `.bak` of the bytes it replaces. For
    /// local contexts this ends up doing the same atomic-rename dance as
    /// before (via `LocalTransport.unguardedWriteFile`); for remote contexts
    /// it goes through `scp` + remote `mv`, still atomic from Hermes's point
    /// of view.
    private func guardedMutate(_ body: (GuardedTextFile.Loaded) -> String?) -> Bool {
        do {
            try guardedFile.mutate(path) { body($0) }
            return true
        } catch {
            logger.error("Refusing to rewrite .env: \(error.localizedDescription)")
            return false
        }
    }

    /// Extract a key name and whether the line was active or commented-out.
    /// Accepts both `KEY=value` and `# KEY=value` (any amount of whitespace after `#`).
    private static func extractKey(fromLine line: String) -> (key: String, active: Bool)? {
        var work = line.trimmingCharacters(in: .whitespaces)
        var active = true
        if work.hasPrefix("#") {
            active = false
            work = String(work.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let eq = work.firstIndex(of: "=") else { return nil }
        let key = String(work[work.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        // Reject non-identifier looking keys to avoid matching prose in comments
        // (e.g. "# This is a note about something = nice").
        // \A…\z, not ^…$: ICU's $ matches before a trailing newline (SEC-L1),
        // and the key is written back into .env lines.
        guard key.range(of: "\\A[A-Za-z_][A-Za-z0-9_]*\\z", options: .regularExpression) != nil else {
            return nil
        }
        return (key, active)
    }

    private static func isCommentedOutAssignment(_ line: String) -> Bool {
        guard let match = extractKey(fromLine: line) else { return false }
        return !match.active
    }

    /// Format a single `KEY=value` line. Values containing whitespace or shell
    /// metacharacters get double-quoted; simple tokens go in unquoted to match
    /// hermes's own output style.
    private static func formatLine(key: String, value: String) -> String {
        if Self.needsQuoting(value) {
            // Escape embedded backslashes and double quotes, then wrap.
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(escaped)\""
        }
        return "\(key)=\(value)"
    }

    private static func needsQuoting(_ value: String) -> Bool {
        if value.isEmpty { return false }
        // Whitespace, shell metacharacters, or quotes trigger quoting.
        let metacharacters: Set<Character> = [" ", "\t", "#", "$", "`", "\"", "'", "\\", "(", ")", "{", "}", "[", "]", "|", "&", ";", "<", ">", "*", "?"]
        return value.contains(where: { metacharacters.contains($0) })
    }

    /// Strip one layer of matched double or single quotes from a loaded value.
    nonisolated private static func stripEnvQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            var inner = String(s.dropFirst().dropLast())
            if first == "\"" {
                inner = inner
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return inner
        }
        return s
    }
}
