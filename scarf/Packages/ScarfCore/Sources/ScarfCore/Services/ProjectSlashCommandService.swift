import Foundation
#if canImport(os)
import os
#endif

/// Loads, saves, and expands user-authored project-scoped slash commands
/// stored at `<project>/.scarf/slash-commands/<name>.md`.
///
/// Each command is a Markdown file with a YAML frontmatter block:
///
/// ```markdown
/// ---
/// name: review
/// description: Code-review the current branch
/// argumentHint: <focus area>
/// model: claude-sonnet-4.5
/// tags:
///   - code-review
///   - git
/// ---
/// You are reviewing changes on the current git branch. …
/// Focus area: {{argument | default: "general code quality"}}.
/// ```
///
/// The service is transport-based — `Mac` reads the local filesystem,
/// `ScarfGo` reads over SFTP via Citadel — so the same code path works
/// on both platforms. Failures are logged but not thrown for `load*`
/// methods because the slash menu degrades gracefully (no commands =
/// menu just shows ACP + quick-command sources).
public struct ProjectSlashCommandService: Sendable {
    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.scarf",
        category: "ProjectSlashCommandService"
    )
    #endif

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Read

    /// List every slash command at `<project>/.scarf/slash-commands/`.
    /// Sorted by `name` ascending. Returns `[]` for projects that have no
    /// `slash-commands/` directory yet — that's the default state for any
    /// project that hasn't authored one.
    public nonisolated func loadCommands(at projectPath: String) -> [ProjectSlashCommand] {
        let dir = Self.slashCommandsDir(for: projectPath)
        let transport = context.makeTransport()
        guard transport.fileExists(dir) else { return [] }

        let entries: [String]
        do {
            entries = try transport.listDirectory(dir)
        } catch {
            #if canImport(os)
            Self.logger.warning(
                "listDirectory failed at \(dir, privacy: .public): \(error.localizedDescription, privacy: .public); returning empty list"
            )
            #endif
            return []
        }

        var commands: [ProjectSlashCommand] = []
        for entry in entries where entry.hasSuffix(".md") {
            let path = dir + "/" + entry
            if let cmd = loadCommand(at: path) {
                commands.append(cmd)
            }
        }
        return commands.sorted { $0.name < $1.name }
    }

    /// Load a single command file by absolute path. Returns nil on any
    /// parse / IO failure (logged).
    public nonisolated func loadCommand(at path: String) -> ProjectSlashCommand? {
        let transport = context.makeTransport()
        do {
            let data = try transport.readFile(path)
            guard let raw = String(data: data, encoding: .utf8) else {
                #if canImport(os)
                Self.logger.warning("non-UTF8 contents at \(path, privacy: .public)")
                #endif
                return nil
            }
            return Self.parse(raw, sourcePath: path)
        } catch {
            #if canImport(os)
            Self.logger.warning(
                "readFile failed at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            #endif
            return nil
        }
    }

    // MARK: - Write

    /// Persist the given command. Throws if the name is invalid or the
    /// transport rejects the write. Creates `<project>/.scarf/slash-commands/`
    /// on demand.
    public nonisolated func save(
        _ command: ProjectSlashCommand,
        at projectPath: String
    ) throws {
        if let reason = ProjectSlashCommand.validateName(command.name) {
            throw ServiceError.invalidName(reason)
        }
        let dir = Self.slashCommandsDir(for: projectPath)
        let transport = context.makeTransport()
        if !transport.fileExists(dir) {
            try transport.createDirectory(dir)
        }
        let path = dir + "/" + command.name + ".md"
        let serialised = Self.serialise(command)
        guard let data = serialised.data(using: .utf8) else {
            throw ServiceError.encodingFailed
        }
        try transport.writeFile(path, data: data)
    }

    /// Remove the command with the given name. No-op if it doesn't exist.
    public nonisolated func delete(
        named name: String,
        at projectPath: String
    ) throws {
        let path = Self.slashCommandsDir(for: projectPath) + "/" + name + ".md"
        let transport = context.makeTransport()
        guard transport.fileExists(path) else { return }
        try transport.removeFile(path)
    }

    // MARK: - Expansion

    /// Render the command's body for sending to the agent. Substitutes
    /// `{{argument}}` (and `{{argument | default: "..."}}`) with the
    /// supplied argument. The result is what `ChatViewModel.sendPrompt`
    /// transmits as a normal user message.
    ///
    /// The expansion also prepends a Scarf-managed marker so the agent
    /// can correlate the prompt back to the slash command — useful when
    /// the agent is asked "what command did the user run?".
    public nonisolated func expand(
        _ command: ProjectSlashCommand,
        withArgument argument: String
    ) -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Self.substituteArgument(in: command.body, with: trimmed)
        return "<!-- scarf-slash:\(command.name) -->\n\(body)"
    }

    // MARK: - Errors

    public enum ServiceError: Error, LocalizedError {
        case invalidName(String)
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .invalidName(let reason): return reason
            case .encodingFailed: return "Couldn't encode the slash command — please check for unusual characters in the body."
            }
        }
    }

    // MARK: - Path helpers

    /// `<project>/.scarf/slash-commands` — same path on Mac + iOS.
    public static func slashCommandsDir(for projectPath: String) -> String {
        let trimmed = projectPath.hasSuffix("/")
            ? String(projectPath.dropLast())
            : projectPath
        return trimmed + "/.scarf/slash-commands"
    }
}

// MARK: - Frontmatter parsing + serialisation

extension ProjectSlashCommandService {
    /// Parse a Markdown file with YAML frontmatter into a
    /// `ProjectSlashCommand`. Returns nil when the frontmatter is missing
    /// or required fields can't be extracted. Reuses `HermesYAML` so we
    /// don't pull in a third-party YAML dependency.
    static func parse(_ raw: String, sourcePath: String) -> ProjectSlashCommand? {
        guard let (frontmatter, body) = splitFrontmatter(raw) else {
            #if canImport(os)
            logger.warning(
                "missing frontmatter at \(sourcePath, privacy: .public); skipping"
            )
            #endif
            return nil
        }
        let parsed = HermesYAML.parseNestedYAML(frontmatter)
        guard let name = parsed.values["name"], !name.isEmpty,
              let description = parsed.values["description"], !description.isEmpty
        else {
            #if canImport(os)
            logger.warning(
                "frontmatter missing required name/description at \(sourcePath, privacy: .public); skipping"
            )
            #endif
            return nil
        }
        return ProjectSlashCommand(
            name: name,
            description: description,
            argumentHint: parsed.values["argumentHint"],
            model: parsed.values["model"],
            tags: parsed.lists["tags"],
            body: body,
            sourcePath: sourcePath
        )
    }

    /// Serialise a command to the on-disk format. Round-trip-safe with
    /// `parse(_:sourcePath:)` for any value that doesn't contain newlines
    /// or YAML-reserved characters in its frontmatter scalars.
    static func serialise(_ command: ProjectSlashCommand) -> String {
        var fm = "---\n"
        fm += "name: \(command.name)\n"
        fm += "description: \(yamlScalar(command.description))\n"
        if let hint = command.argumentHint, !hint.isEmpty {
            fm += "argumentHint: \(yamlScalar(hint))\n"
        }
        if let model = command.model, !model.isEmpty {
            fm += "model: \(yamlScalar(model))\n"
        }
        if let tags = command.tags, !tags.isEmpty {
            fm += "tags:\n"
            for tag in tags {
                fm += "  - \(yamlScalar(tag))\n"
            }
        }
        fm += "---\n"
        // Body always ends with one trailing newline so editors don't
        // produce diffs on save when the user typed cleanly.
        var body = command.body
        if !body.hasSuffix("\n") { body += "\n" }
        return fm + body
    }

    /// Wrap a scalar in double quotes when it contains characters that
    /// HermesYAML's parser treats as structural (`:`, `#`, leading `-`,
    /// etc.). Otherwise emit it bare.
    private static func yamlScalar(_ value: String) -> String {
        let needsQuoting = value.contains(":")
            || value.contains("#")
            || value.contains("\"")
            || value.hasPrefix("-")
            || value.hasPrefix("[")
            || value.hasPrefix("{")
            || value.hasPrefix(">")
            || value.hasPrefix("|")
        if !needsQuoting { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Split a Markdown-with-frontmatter string at the closing `---`.
    /// Returns `(frontmatter, body)` or nil when no frontmatter is found.
    /// The opening `---` must be the very first line of the file (any
    /// leading whitespace/newlines disqualify the file — keeps the
    /// detection unambiguous).
    static func splitFrontmatter(_ raw: String) -> (frontmatter: String, body: String)? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        for (idx, line) in lines.enumerated() where idx > 0 && line == "---" {
            let frontmatter = lines[1..<idx].joined(separator: "\n")
            let bodyStart = idx + 1
            let body: String
            if bodyStart >= lines.count {
                body = ""
            } else {
                // Drop a single blank line right after `---` (common
                // Markdown style; preserves the body's first real line).
                var bodyLines = Array(lines[bodyStart...])
                if bodyLines.first == "" { bodyLines.removeFirst() }
                body = bodyLines.joined(separator: "\n")
            }
            return (frontmatter, body)
        }
        return nil
    }

    /// Replace `{{argument}}` and `{{argument | default: "..."}}` in the
    /// template body with the user-supplied argument. Default value is
    /// used when the argument is empty / whitespace-only.
    static func substituteArgument(in template: String, with argument: String) -> String {
        var result = template
        // Match {{argument | default: "..."}} first (more specific).
        let defaultPattern = #"\{\{\s*argument\s*\|\s*default:\s*"((?:[^"\\]|\\.)*)"\s*\}\}"#
        if let regex = try? NSRegularExpression(pattern: defaultPattern) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: range).reversed()
            for match in matches {
                guard let fullRange = Range(match.range, in: result),
                      let defaultRange = Range(match.range(at: 1), in: result)
                else { continue }
                let replacement = argument.isEmpty
                    ? String(result[defaultRange])
                    : argument
                result.replaceSubrange(fullRange, with: replacement)
            }
        }
        // Then plain {{argument}} for anything that didn't have a default.
        result = result.replacingOccurrences(
            of: #"\{\{\s*argument\s*\}\}"#,
            with: argument,
            options: .regularExpression
        )
        return result
    }
}
