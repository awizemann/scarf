import Foundation

/// A single entry from Hermes's "Nous-approved" optional MCP catalog
/// (`optional-mcps/<name>/manifest.yaml` in hermes-agent). Hermes's own
/// catalog grew from 6 to 20 entries in v0.20.4 (blender was removed).
/// Scarf has no `hermes mcp install` equivalent — this roster feeds a
/// minimal picker in the add-server flow that prefills
/// `MCPServerAddCustomView`'s fields; installing local (stdio git-clone)
/// entries like `n8n` still requires the user to fill in the command
/// themselves after prefill, since Scarf doesn't run the catalog's
/// `install:` bootstrap steps.
public struct OptionalMCPCatalogEntry: Identifiable, Sendable, Equatable {
    /// How the catalog entry authenticates. Mirrors the manifest's `auth.type`.
    public enum AuthKind: String, Sendable, Equatable {
        case oauth
        case apiKey = "api_key"
        case none
    }

    public let name: String
    public let description: String
    public let transport: MCPTransport
    public let authKind: AuthKind
    /// The env var Hermes prompts for when `authKind == .apiKey` (e.g. the
    /// n8n bridge's `N8N_API_KEY`). Empty for oauth/none entries — those
    /// have no required env var in the manifest.
    public let requiredEnvVar: String
    /// Populated only for `.http`/`.sse` entries — the hosted MCP endpoint
    /// from the manifest's `transport.url`. `nil` for stdio entries, whose
    /// `transport.command` depends on a local install step Scarf doesn't
    /// perform.
    public let url: String?

    public var id: String { name }

    public init(
        name: String,
        description: String,
        transport: MCPTransport,
        authKind: AuthKind,
        requiredEnvVar: String = "",
        url: String? = nil
    ) {
        self.name = name
        self.description = description
        self.transport = transport
        self.authKind = authKind
        self.requiredEnvVar = requiredEnvVar
        self.url = url
    }
}

/// Static, verbatim-captured roster of Hermes v0.20.4's (tag `v2026.8.18`)
/// 20 `optional-mcps/*/manifest.yaml` entries. Name/description/transport/
/// auth were read directly from each manifest — see
/// `documents/hermes-v0.20.4-audit-report.md` for the capture session.
/// Hermes's own catalog can add/remove entries between releases; this list
/// is a point-in-time snapshot, not a live fetch.
public enum OptionalMCPCatalog {
    public static let entries: [OptionalMCPCatalogEntry] = [
        OptionalMCPCatalogEntry(
            name: "airtable",
            description: "Bases, tables, and records from your Airtable workspace.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.airtable.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "asana",
            description: "Tasks, projects, and goals from your Asana workspace.",
            transport: .sse,
            authKind: .oauth,
            url: "https://mcp.asana.com/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "atlassian",
            description: "Jira issues and Confluence pages via Atlassian's hosted remote MCP.",
            transport: .sse,
            authKind: .oauth,
            url: "https://mcp.atlassian.com/v1/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "comfy-cloud",
            description: "Generate images, video, audio, and 3D on Comfy Cloud.",
            transport: .http,
            authKind: .oauth,
            url: "https://cloud.comfy.org/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "datadog",
            description: "Logs, monitors, dashboards, and incidents from Datadog.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.datadoghq.com/api/unstable/mcp-server/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "figma",
            description: "Official Figma remote MCP — design context, Code Connect, and write-to-canvas.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.figma.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "hugging_face",
            description: "Models, datasets, Spaces, and papers from the Hugging Face Hub.",
            transport: .http,
            authKind: .oauth,
            url: "https://huggingface.co/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "intercom",
            description: "Conversations, tickets, and customer data from Intercom.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.intercom.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "linear",
            description: "Find, create, and update Linear issues, projects, and comments.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.linear.app/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "n8n",
            description: "Manage and inspect n8n workflows from Hermes (stdio bridge, no public port).",
            transport: .stdio,
            authKind: .apiKey,
            requiredEnvVar: "N8N_API_KEY"
        ),
        OptionalMCPCatalogEntry(
            name: "netlify",
            description: "Sites, deploys, and env vars via Netlify's hosted MCP.",
            transport: .http,
            authKind: .oauth,
            url: "https://netlify-mcp.netlify.app/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "notion",
            description: "Pages and databases from your Notion workspace.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.notion.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "paypal",
            description: "Payments, invoices, and subscriptions via PayPal's hosted MCP.",
            transport: .sse,
            authKind: .oauth,
            url: "https://mcp.paypal.com/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "sentry",
            description: "Issues, stack traces, and error context from Sentry.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.sentry.dev/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "square",
            description: "Catalog, orders, and payments via Square's hosted MCP.",
            transport: .sse,
            authKind: .oauth,
            url: "https://mcp.squareup.com/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "stripe",
            description: "Payments, customers, and invoices via Stripe's hosted MCP.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.stripe.com"
        ),
        OptionalMCPCatalogEntry(
            name: "supabase",
            description: "Database, auth, and storage from your Supabase projects.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.supabase.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "unreal-engine",
            description: "Drive the Unreal Engine 5.8 editor over its local MCP server.",
            transport: .http,
            authKind: .none,
            url: "http://127.0.0.1:8000/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "vercel",
            description: "Deployments, logs, and projects via Vercel's hosted MCP.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.vercel.com"
        ),
        OptionalMCPCatalogEntry(
            name: "webflow",
            description: "Sites, CMS collections, and pages via Webflow's hosted MCP.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.webflow.com/mcp"
        ),
    ]
}
