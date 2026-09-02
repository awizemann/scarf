import Foundation

/// Validation for the two user-typed overrides on the "Install skill from
/// URL" sheet (`hermes skills install <url> --category <c> --name <n>`).
///
/// The shapes here are Hermes's own, read from `hermes_cli/skills_hub.py`
/// (v2026.8.31), NOT invented for Scarf:
///
/// ```python
/// _VALID_NAME_RE     = re.compile(r"^[a-z][a-z0-9_-]*$")
/// _VALID_CATEGORY_RE = re.compile(r"^[a-z][a-z0-9_/-]*$")
/// ```
///
/// The two differ deliberately: a category MAY contain `/` (nested buckets
/// — `do_install` builds one as `"/".join(id_parts[1:-1])` for official
/// skills), a name may not. Names are additionally rejected when they are
/// one of Hermes's sentinel words.
///
/// Why validate at all, per side:
///
///  - **`--name`**: Hermes checks it via `_is_valid_installed_skill_name`
///    and, on the URL-install path, aborts with `Invalid --name:` printed
///    to stdout. Scarf's install then reported a canned "Install failed"
///    with the real reason buried, after a download and a scan.
///  - **`--category`**: Hermes applies `_VALID_CATEGORY_RE` **only** to the
///    value it prompts for interactively. A category passed as a CLI flag
///    is never validated — it is interpolated straight into the install
///    path (`~/.hermes/skills/{category}/{name}/`). So a `..` segment
///    typed into this sheet writes the skill OUTSIDE the skills root.
///    Scarf is the last line of defence for that field.
public enum SkillInstallValidator {
    /// Which field is being validated — they have different legal shapes.
    public enum Field: Sendable {
        case name
        case category
    }

    public enum Problem: Equatable, Sendable {
        case empty
        case relativePathComponent
        case separatorNotAllowed
        case mustStartWithLowercaseLetter
        case disallowedCharacter(Character)
        case reservedName(String)

        /// Shown under the offending field. The Install button is disabled
        /// while any of these stand, so this is the whole explanation.
        public var userMessage: String {
            switch self {
            case .empty:
                return "Cannot be blank — clear the field to let Hermes choose."
            case .relativePathComponent:
                return "`.` and `..` segments are not allowed — they would install outside the skills folder."
            case .separatorNotAllowed:
                return "A skill name cannot contain `/` or `\\` — it is a single folder name."
            case .mustStartWithLowercaseLetter:
                return "Must start with a lowercase letter (a–z)."
            case .disallowedCharacter(let c):
                return "`\(c)` is not allowed. Hermes accepts lowercase letters, digits, `-` and `_`."
            case .reservedName(let n):
                return "`\(n)` is reserved by Hermes — pick a more specific name."
            }
        }
    }

    /// `_is_valid_installed_skill_name`'s sentinel set.
    private static let reservedNames: Set<String> = ["skill", "readme", "index", "unnamed-skill"]

    /// Validate one override. A value that is absent or empty means "not
    /// supplied" — the flag is simply omitted, which is legal — so that
    /// returns `nil`. A value the user typed that is only whitespace is
    /// `.empty`, because they clearly meant to type something.
    public static func problem(with raw: String?, field: Field) -> Problem? {
        guard let raw, !raw.isEmpty else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }

        // Path safety first, and independent of the character rules below,
        // so the message names the real hazard rather than blaming a dot.
        if value.contains("\\") {
            return field == .name ? .separatorNotAllowed : .disallowedCharacter("\\")
        }
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: { $0 == "." || $0 == ".." }) {
            return .relativePathComponent
        }
        if field == .name && value.contains("/") { return .separatorNotAllowed }

        guard let first = value.first, first.isLowercaseASCIILetter else {
            return .mustStartWithLowercaseLetter
        }
        for character in value.dropFirst() {
            guard character.isAllowedInSkillIdentifier(field: field) else {
                return .disallowedCharacter(character)
            }
        }
        if field == .name && reservedNames.contains(value) {
            return .reservedName(value)
        }
        return nil
    }

    /// Convenience for a view's `disabled(...)`.
    public static func isAcceptable(_ raw: String?, field: Field) -> Bool {
        problem(with: raw, field: field) == nil
    }
}

private extension Character {
    var isLowercaseASCIILetter: Bool {
        self >= "a" && self <= "z"
    }

    /// Mirrors the interior character classes of Hermes's two regexes.
    func isAllowedInSkillIdentifier(field: SkillInstallValidator.Field) -> Bool {
        if isLowercaseASCIILetter { return true }
        if self >= "0" && self <= "9" { return true }
        if self == "-" || self == "_" { return true }
        if self == "/" && field == .category { return true }
        return false
    }
}
