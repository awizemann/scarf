import Foundation

/// Parser for `hermes profile list` output, shared by the Mac Profiles view
/// and ScarfGo's profile picker (S13-F4: ScarfGo used to take each row's
/// first word, which drops or mis-ids every profile with a display name).
///
/// Hermes prints a fixed-width table (`hermes_cli/profile_cmd.py:108-124` @
/// v2026.9.24):
///
///      Profile          Model                        Gateway      Alias        Distribution
///      ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
///     ◆default          gpt-5                        stopped      —            —
///      Research Bot (research) claude-x              running      research     —
///
/// Since 0.20.5 a profile with a display name renders as `Display Name (id)`
/// (`format_profile_label`, `hermes_cli/profiles.py:906-910`). Display names
/// are free text (spaces, parens, up to 64 chars), while canonical ids match
/// `^[a-z0-9][a-z0-9_-]{0,63}$` and can never contain a space or a paren, so
/// a parenthesized id-shaped token in the Profile field is unambiguous.
///
/// The `◆` marker is Hermes' `get_active_profile_name()`, which is derived
/// from the PROCESS's `HERMES_HOME` (`profiles.py:1941-1955`), not from the
/// sticky `active_profile` file. So it names the server's active profile
/// only for an unpinned local run; a pinned (remote) run marks the pinned
/// profile. Callers that need the server's active profile on a remote host
/// read `<root>/active_profile` instead.
public enum HermesProfileList {

    /// One parsed row.
    public struct Row: Sendable, Equatable {
        /// The canonical profile id (what `-p` takes).
        public let id: String
        /// The display name when Hermes printed one (`Display Name (id)`).
        public let displayName: String?
        /// Whether the row carried the `◆` (or legacy `*`) marker.
        public let isMarked: Bool

        public init(id: String, displayName: String?, isMarked: Bool) {
            self.id = id
            self.displayName = displayName
            self.isMarked = isMarked
        }
    }

    private static let idParenPattern =
        try! NSRegularExpression(pattern: "\\(([a-z0-9][a-z0-9_-]{0,63})\\)")

    /// Parse the table. Rows are returned in printed order, deduplicated by id.
    ///
    /// The row is printed as `f"{marker}{name:<15} {model:<28} …"`: fixed-width
    /// fields separated by a single literal space, so a field shorter than its
    /// width leaves a run of 2+ spaces before the next field while a display
    /// name may still contain single spaces. We split on runs of 2+ spaces to
    /// isolate field 0 before searching it for a `(canonical-id)` group.
    ///
    /// Field 0 is the label alone only while the label fits its 15-column
    /// width. A longer label (most display-named rows) overflows, and then
    /// the one-space separator is all that divides it from the Model, so
    /// field 0 is `<label> <model>`. The model is never empty (Hermes prints
    /// `—` for none) and is at most 26 characters. So the id is the last
    /// `(id)` group that either ends field 0 (no overflow) or, on an
    /// overflowed row, ends a label of 15+ characters and is followed by a
    /// space and a model. That keeps an id-shaped parenthetical in the model
    /// (`gpt-4o (preview)`) or earlier in the display name ("My (test)
    /// profile (myid)") from being taken for the id. With no group, field
    /// 0's first token is the bare id, which is what pre-0.20.5 hosts print.
    public static func parse(_ output: String) -> [Row] {
        var rows: [Row] = []
        var seen = Set<String>()
        var sawHeader = false

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Box-drawing separator rows: only ─ (U+2500) and whitespace.
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) { continue }
            // Header row (first non-empty, non-separator line in the table).
            if !sawHeader && line.lowercased().contains("profile") && line.lowercased().contains("gateway") {
                sawHeader = true
                continue
            }
            var working = line
            var isMarked = false
            if working.hasPrefix("◆") || working.hasPrefix("*") {
                isMarked = true
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let fields = working.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let field0 = fields.first else { continue }
            let ns = field0 as NSString
            let matches = idParenPattern.matches(in: field0, range: NSRange(location: 0, length: ns.length))
            let id: String
            var displayName: String?
            if let match = Self.labelIDMatch(matches, in: ns) {
                id = ns.substring(with: match.range(at: 1))
                let label = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
                displayName = label.isEmpty ? nil : label
            } else {
                guard let token = field0.split(whereSeparator: { $0.isWhitespace }).first else { continue }
                id = String(token)
            }
            // Reject rows whose extracted name is something like "Tip:" or a
            // localized label — ids are alphanumeric with - or _. \A…\z, not
            // ^…$: ICU's $ matches before a trailing newline, and this id
            // becomes a `hermes -p` argument.
            guard id.range(of: "\\A[a-zA-Z0-9_-]+\\z", options: .regularExpression) != nil else { continue }
            guard seen.insert(id).inserted else { continue }
            rows.append(Row(id: id, displayName: displayName, isMarked: isMarked))
        }
        return rows
    }

    /// Hermes' Profile column width (`{name:<15}`) and Model truncation
    /// (`[:26]`), `hermes_cli/profile_cmd.py:119-124` @ v2026.9.24.
    private static let labelWidth = 15
    private static let modelMaxLength = 26

    /// The `(id)` group that closes the label, per the rules in ``parse(_:)``.
    private static func labelIDMatch(_ matches: [NSTextCheckingResult], in field0: NSString) -> NSTextCheckingResult? {
        // Python pads by code points, so widths are counted in Unicode
        // scalars, not UTF-16 units (an emoji in a display name is one
        // column to Hermes but two units here).
        func width(_ s: String) -> Int { s.unicodeScalars.count }
        for match in matches.reversed() {
            let end = match.range.location + match.range.length
            let labelWidthSoFar = width(field0.substring(to: end))
            if end == field0.length {
                // Ends the field: the whole field is the label. That is only
                // possible when the label didn't overflow into the model.
                if labelWidthSoFar <= labelWidth { return match }
                continue
            }
            // Overflowed: `<label> <model>`, label at least 15 wide.
            guard labelWidthSoFar >= labelWidth,
                  field0.substring(with: NSRange(location: end, length: 1)) == " " else { continue }
            let model = field0.substring(from: end + 1).trimmingCharacters(in: .whitespaces)
            if !model.isEmpty && width(model) <= modelMaxLength { return match }
        }
        // No group closes the label: a bare id (the first-token fallback).
        return nil
    }

    /// The server's active profile from the raw contents of
    /// `<root>/active_profile`: trimmed, and missing/empty → `default`,
    /// mirroring Hermes' `get_active_profile` (`profiles.py:1909-1915`).
    public static func activeProfile(fromFileContents contents: String?) -> String {
        let trimmed = contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? HermesProfileScope.defaultProfileName : trimmed
    }
}
