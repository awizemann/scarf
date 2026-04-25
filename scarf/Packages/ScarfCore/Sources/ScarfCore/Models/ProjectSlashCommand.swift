import Foundation

/// A user-authored, project-scoped slash command. Lives at
/// `<project>/.scarf/slash-commands/<name>.md` as a Markdown file with
/// YAML frontmatter — Scarf-side primitive, not a Hermes feature.
///
/// The command is invoked via the chat slash menu like any other command,
/// but Scarf intercepts the invocation client-side: the body is treated as
/// a prompt template (with `{{argument}}` substitution from whatever
/// followed the slash), expanded to a regular user prompt, and sent to
/// Hermes as a normal message. The agent never sees the slash trigger;
/// it sees the expanded prompt prefixed with a `<!-- scarf-slash:<name> -->`
/// marker so it can correlate.
///
/// **Why client-side expansion.** Hermes has no project-scoped slash
/// command concept. Doing the substitution in Scarf means commands work
/// uniformly on Mac + iOS, local + remote SSH transports, against any
/// Hermes version (no upstream dependency).
public struct ProjectSlashCommand: Sendable, Equatable, Identifiable {
    /// Stable identity is the command's `name` (must be unique within a
    /// project's `slash-commands/` dir).
    public var id: String { name }

    /// Slash trigger — drives the menu and the on-disk filename.
    /// Must match `[a-z][a-z0-9-]*`. Validated by the service on save.
    public let name: String

    /// Human-readable subtitle shown in the slash menu.
    public let description: String

    /// Optional placeholder shown after `/<name> ` in the menu (e.g. `<focus area>`).
    public let argumentHint: String?

    /// Optional per-command model override. When set, the expanded prompt
    /// is sent with this model in the ACP envelope, regardless of the
    /// session's default.
    public let model: String?

    /// Optional grouping tags for the catalog / editor UI. Not surfaced
    /// to the agent.
    public let tags: [String]?

    /// The prompt template body (everything after the YAML frontmatter
    /// closer). Mustache-style `{{argument}}` substitution; supports
    /// `{{argument | default: "..."}}` for fallbacks.
    public let body: String

    /// Absolute path the command was loaded from (used by the editor's
    /// save/delete affordances + by the uninstaller's lock-file tracking).
    public let sourcePath: String

    public init(
        name: String,
        description: String,
        argumentHint: String? = nil,
        model: String? = nil,
        tags: [String]? = nil,
        body: String,
        sourcePath: String
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.model = model
        self.tags = tags
        self.body = body
        self.sourcePath = sourcePath
    }
}

// MARK: - Validation

public extension ProjectSlashCommand {
    /// Allowed name shape: lowercase, digits, hyphens; must start with a
    /// letter. Mirrors the catalog validator's rule so on-disk files
    /// authored in Scarf round-trip cleanly through `.scarftemplate`.
    static let validNamePattern = #"^[a-z][a-z0-9-]*$"#

    /// Returns nil when the name is well-formed; otherwise a human-readable
    /// reason suitable for inline editor UX.
    static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "Name can't be empty." }
        if name.count > 64 { return "Name must be 64 characters or fewer." }
        if name.range(of: validNamePattern, options: .regularExpression) == nil {
            return "Name must start with a letter and contain only lowercase letters, digits, and hyphens."
        }
        return nil
    }
}
