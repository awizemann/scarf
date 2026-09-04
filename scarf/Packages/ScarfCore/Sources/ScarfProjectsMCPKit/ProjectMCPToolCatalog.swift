import Foundation
import ScarfCore

/// The `tools/list` payload — the schemas the model actually sees.
///
/// These descriptions are the whole reason this is an MCP server rather
/// than a CLI: the agent reads the contract before it writes, instead of
/// reading a skill's prose and hoping. Keep them blunt about what a tool
/// refuses, because a refusal the model can anticipate is a retry it
/// never makes.
public enum ProjectMCPToolCatalog {

    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: JSONValue
    }

    public static let tools: [Tool] = [
        Tool(
            name: "project_list",
            description: """
                List every Scarf project on this machine, with whether each one has a canonical \
                record (.scarf/project.json) and a dashboard. Also reports the health of the \
                projects registry — when that is damaged, every write tool here refuses until \
                it is repaired.
                """,
            inputSchema: object(
                properties: [
                    "includeArchived": schema(
                        "boolean",
                        "Include archived projects. Defaults to true."
                    ),
                ],
                required: []
            )
        ),
        Tool(
            name: "project_get",
            description: """
                Everything Scarf knows about one project: its registry row, its canonical record, \
                whether its dashboard parses, and its slash commands. Accepts a display name or \
                an absolute path.
                """,
            inputSchema: object(
                properties: [
                    "project": schema("string", "Project display name, or its absolute path."),
                ],
                required: ["project"]
            )
        ),
        Tool(
            name: "project_register",
            description: """
                Register an EXISTING directory as a Scarf project: writes \
                <path>/.scarf/project.json with a stable id and adds the registry row. Use this \
                instead of editing ~/.hermes/scarf/projects.json by hand — a hand-written row \
                with a malformed field is how projects disappear from Scarf. The directory must \
                already exist; this never creates it. Refuses a duplicate name or a path that is \
                already registered.
                """,
            inputSchema: object(
                properties: [
                    "name": schema("string", "Display name. Must be unique across projects."),
                    "path": schema(
                        "string",
                        "Absolute path to the existing project directory. `~` is not expanded."
                    ),
                ],
                required: ["name", "path"]
            )
        ),
        Tool(
            name: "project_update_dashboard",
            description: """
                Replace a project's .scarf/dashboard.json. The JSON is validated against Scarf's \
                real dashboard schema and widget catalog BEFORE anything is written: on any \
                problem nothing is written and the exact offending fields come back by JSON path. \
                Widget types: stat, progress, text, table, chart, list, webview, markdown_file, \
                log_tail, cron_status, image, status_grid, kanban_summary. Shape: {"version": 1, \
                "title": "...", "sections": [{"title": "...", "columns": 3, "widgets": [...]}]}.
                """,
            inputSchema: object(
                properties: [
                    "project": schema("string", "Project display name, or its absolute path."),
                    "dashboard": .object([
                        "description": .string(
                            "The complete dashboard document. Replaces the existing file."
                        ),
                    ]),
                ],
                required: ["project", "dashboard"]
            )
        ),
        Tool(
            name: "project_add_slash_command",
            description: """
                Add a project-scoped slash command at \
                <project>/.scarf/slash-commands/<name>.md. The body may use {{argument}} and \
                {{argument | default: "..."}}. Refuses an existing command unless overwrite is \
                true.
                """,
            inputSchema: object(
                properties: [
                    "project": schema("string", "Project display name, or its absolute path."),
                    "name": schema(
                        "string",
                        "Command name without the slash. Lowercase letters, digits and hyphens; "
                            + "must start with a letter."
                    ),
                    "description": schema("string", "One line shown in the slash menu."),
                    "body": schema("string", "The prompt text sent when the command runs."),
                    "argumentHint": schema("string", "Placeholder shown for the argument."),
                    "model": schema("string", "Model override for this command."),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Tags for grouping in the slash menu."),
                    ]),
                    "overwrite": schema(
                        "boolean",
                        "Replace an existing command of the same name. Defaults to false."
                    ),
                ],
                required: ["project", "name", "description", "body"]
            )
        ),
        Tool(
            name: "project_validate",
            description: """
                Run Scarf's Project Doctor: reconciles the registry, each project's \
                .scarf/project.json and what is actually on disk, and reports what disagrees. \
                Pass a project to scope the report to one. Pass repair: true to apply only the \
                repairs Scarf considers safe — never destructive ones, and never any while the \
                registry itself is damaged.
                """,
            inputSchema: object(
                properties: [
                    "project": schema(
                        "string",
                        "Scope to one project (display name or absolute path). "
                            + "Omit for the whole registry."
                    ),
                    "repair": schema(
                        "boolean",
                        "Apply safe repairs. Defaults to false (report only)."
                    ),
                ],
                required: []
            )
        ),
        Tool(
            name: "project_set_config",
            description: """
                Write one key into a project's .scarf/config.json. Non-secret values (string, \
                number, boolean, or array of strings) are written inline. Pass secret: true for a \
                value that must never appear in config.json in plaintext: it is routed through \
                macOS Keychain (the same code path Scarf's Configuration UI uses) and only a \
                "keychain://com.scarf.template.<slug>/..." reference is written to disk. A field \
                declared `secret` in the project's cached template manifest MUST be written with \
                secret: true, and vice versa; a plaintext "keychain://" value in `value` is always \
                refused. Secret fields require a template-installed project (a cached \
                .scarf/manifest.json) so there is a template slug to namespace the Keychain item \
                under — for a hand-registered project without one, set secrets from Scarf's \
                Configuration UI instead.
                """,
            inputSchema: object(
                properties: [
                    "project": schema("string", "Project display name, or its absolute path."),
                    "key": schema(
                        "string",
                        "Config key. Letters, digits, '-', '_' or '.' only."
                    ),
                    "value": .object([
                        "description": .string(
                            "The value to write. A plaintext string, number, boolean, or array "
                                + "of strings. When secret: true, this is the plaintext secret "
                                + "itself — never a keychain:// reference, which is always refused."
                        ),
                    ]),
                    "secret": schema(
                        "boolean",
                        "Route the value through Keychain instead of writing it inline. Defaults "
                            + "to false. Must match the field's declared type in the project's "
                            + "cached template manifest when one exists."
                    ),
                ],
                required: ["project", "key", "value"]
            )
        ),
    ]

    /// `tools/list` result.
    public static func listResult() -> JSONValue {
        .object([
            "tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                ])
            }),
        ])
    }

    // MARK: - Schema helpers

    private static func schema(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func object(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }
}
