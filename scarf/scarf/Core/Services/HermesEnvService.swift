import Foundation
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
struct HermesEnvService: Sendable {
    private let logger = Logger(subsystem: "com.scarf", category: "HermesEnvService")

    /// Path to `~/.hermes/.env`. Kept configurable for tests.
    let path: String
    let transport: any ServerTransport

    nonisolated init(context: ServerContext = .local) {
        self.path = context.paths.envFile
        self.transport = context.makeTransport()
    }

    /// Escape hatch for tests that want to point at a fixture path directly.
    init(path: String) {
        self.path = path
        self.transport = LocalTransport()
    }

    /// Read the .env file into a `[key: value]` dict. Comments and commented-out
    /// assignments are ignored. Missing file returns an empty dict.
    func load() -> [String: String] {
        guard let data = try? transport.readFile(path),
              let content = String(data: data, encoding: .utf8) else {
            return [:]
        }
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
        var remaining = pairs
        var lines: [String]

        // Start from existing file contents, or a minimal header if creating new.
        if let data = try? transport.readFile(path),
           let content = String(data: data, encoding: .utf8) {
            lines = content.components(separatedBy: "\n")
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

        return atomicWrite(lines.joined(separator: "\n") + "\n")
    }

    /// Comment out a key. The value is preserved so the user can restore by
    /// uncommenting. If the key doesn't exist, this is a no-op.
    @discardableResult
    func unset(_ key: String) -> Bool {
        guard let data = try? transport.readFile(path),
              let content = String(data: data, encoding: .utf8) else {
            return true
        }
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var changed = false
        for (idx, line) in lines.enumerated() {
            guard let match = Self.extractKey(fromLine: line), match.key == key else { continue }
            // Skip lines that are already commented — nothing to do.
            if Self.isCommentedOutAssignment(line) { continue }
            lines[idx] = "# " + line
            changed = true
        }
        guard changed else { return true }
        return atomicWrite(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Internals

    /// Writes the entire file in one shot through the transport. For local
    /// contexts this ends up doing the same atomic-rename dance as before
    /// (via `LocalTransport.writeFile`). For remote contexts this goes
    /// through `scp` + remote `mv`, still atomic from Hermes's point of
    /// view.
    private func atomicWrite(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8) else { return false }
        do {
            try transport.writeFile(path, data: data)
            return true
        } catch {
            logger.error("Failed to write .env: \(error.localizedDescription)")
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
        guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
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
    private static func stripEnvQuotes(_ s: String) -> String {
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
