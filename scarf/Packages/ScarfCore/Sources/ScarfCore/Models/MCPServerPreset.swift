import Foundation

public struct MCPServerPreset: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let description: String
    public let category: String
    public let iconSystemName: String
    public let transport: MCPTransport
    public let command: String?
    public let args: [String]
    public let url: String?
    public let auth: String?
    public let requiredEnvKeys: [String]
    public let optionalEnvKeys: [String]
    public let pathArgPrompt: String?
    public let docsURL: String


    public init(
        id: String,
        displayName: String,
        description: String,
        category: String,
        iconSystemName: String,
        transport: MCPTransport,
        command: String?,
        args: [String],
        url: String?,
        auth: String?,
        requiredEnvKeys: [String],
        optionalEnvKeys: [String],
        pathArgPrompt: String?,
        docsURL: String
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.category = category
        self.iconSystemName = iconSystemName
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.auth = auth
        self.requiredEnvKeys = requiredEnvKeys
        self.optionalEnvKeys = optionalEnvKeys
        self.pathArgPrompt = pathArgPrompt
        self.docsURL = docsURL
    }
    public static let gallery: [MCPServerPreset] = [
        MCPServerPreset(
            id: "filesystem",
            displayName: "Filesystem",
            description: "Read and write files under a root directory you choose.",
            category: "Built-in",
            iconSystemName: "folder",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"],
            url: nil,
            auth: nil,
            requiredEnvKeys: [],
            optionalEnvKeys: [],
            pathArgPrompt: "Root directory (absolute path)",
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem"
        ),
        MCPServerPreset(
            id: "github",
            displayName: "GitHub",
            description: "Issues, pull requests, code search, and file operations via GitHub API.",
            category: "Dev",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            url: nil,
            auth: nil,
            requiredEnvKeys: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            optionalEnvKeys: [],
            pathArgPrompt: nil,
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/github"
        ),
        MCPServerPreset(
            id: "postgres",
            displayName: "Postgres",
            description: "Read-only SQL access against a Postgres database.",
            category: "Data",
            iconSystemName: "cylinder.split.1x2",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-postgres"],
            url: nil,
            auth: nil,
            requiredEnvKeys: [],
            optionalEnvKeys: [],
            pathArgPrompt: "Connection URL (postgres://user:pass@host/db)",
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/postgres"
        ),
        MCPServerPreset(
            id: "slack",
            displayName: "Slack",
            description: "Read channels, post messages, and search your Slack workspace.",
            category: "Productivity",
            iconSystemName: "bubble.left.and.bubble.right",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-slack"],
            url: nil,
            auth: nil,
            requiredEnvKeys: ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"],
            optionalEnvKeys: [],
            pathArgPrompt: nil,
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/slack"
        ),
        MCPServerPreset(
            id: "linear",
            displayName: "Linear",
            description: "Query and update Linear issues. Uses OAuth — no token needed.",
            category: "Productivity",
            iconSystemName: "list.bullet.rectangle",
            transport: .http,
            command: nil,
            args: [],
            url: "https://mcp.linear.app/sse",
            auth: "oauth",
            requiredEnvKeys: [],
            optionalEnvKeys: [],
            pathArgPrompt: nil,
            docsURL: "https://linear.app/docs/mcp"
        ),
        MCPServerPreset(
            id: "sentry",
            displayName: "Sentry",
            description: "Investigate errors and performance issues from Sentry.",
            category: "Dev",
            iconSystemName: "exclamationmark.triangle",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@sentry/mcp-server"],
            url: nil,
            auth: nil,
            requiredEnvKeys: ["SENTRY_AUTH_TOKEN", "SENTRY_ORG"],
            optionalEnvKeys: [],
            pathArgPrompt: nil,
            docsURL: "https://docs.sentry.io/product/mcp/"
        ),
        MCPServerPreset(
            id: "puppeteer",
            displayName: "Puppeteer",
            description: "Headless browser automation — navigate pages, click, screenshot.",
            category: "Automation",
            iconSystemName: "safari",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-puppeteer"],
            url: nil,
            auth: nil,
            requiredEnvKeys: [],
            optionalEnvKeys: [],
            pathArgPrompt: nil,
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/puppeteer"
        ),
        MCPServerPreset(
            id: "memory",
            displayName: "Memory (Knowledge Graph)",
            description: "Persistent knowledge graph of entities and relations across sessions.",
            category: "Built-in",
            iconSystemName: "brain",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-memory"],
            url: nil,
            auth: nil,
            requiredEnvKeys: [],
            optionalEnvKeys: ["MEMORY_FILE_PATH"],
            pathArgPrompt: nil,
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory"
        ),
        MCPServerPreset(
            id: "fetch",
            displayName: "Fetch",
            description: "Retrieve and convert web pages to markdown.",
            category: "Built-in",
            iconSystemName: "arrow.down.circle",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-fetch"],
            url: nil,
            auth: nil,
            requiredEnvKeys: [],
            optionalEnvKeys: [],
            pathArgPrompt: nil,
            docsURL: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch"
        )
    ]

    public static var categories: [String] {
        var seen = Set<String>()
        return gallery.compactMap { p in seen.insert(p.category).inserted ? p.category : nil }
    }

    public static func byCategory(_ category: String) -> [MCPServerPreset] {
        gallery.filter { $0.category == category }
    }
}
