import Foundation

/// A single entry from Hermes's "Nous-approved" optional MCP catalog
/// (`optional-mcps/<name>/manifest.yaml` in hermes-agent). Hermes's own
/// catalog grew from 6 to 20 entries in v0.20.4 (blender was removed), and
/// to 65 entries in v0.21.0.
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
    /// The env vars Hermes prompts for when `authKind == .apiKey`, in
    /// manifest order (`auth.env[].name`). A manifest may declare more than
    /// one — the n8n bridge requires BOTH `N8N_BASE_URL` (non-secret,
    /// defaulted to `http://127.0.0.1:5678`) and `N8N_API_KEY` (secret) —
    /// so this is plural. Empty for oauth/none entries, which declare no
    /// `auth.env` block at all.
    public let requiredEnvVars: [String]
    /// Populated only for `.http`/`.sse` entries — the hosted MCP endpoint
    /// from the manifest's `transport.url`. `nil` for stdio entries, whose
    /// `transport.command` depends on a local install step Scarf doesn't
    /// perform.
    public let url: String?
    /// Mirrors the manifest's `tools.default_enabled` — tool names
    /// pre-checked in Hermes's install-time checklist. Mutually exclusive
    /// with `defaultExcludedTools`; empty when the manifest declares
    /// neither (all probed tools are pre-checked).
    public let defaultEnabledTools: [String]
    /// Mirrors the manifest's `tools.default_excluded` — tool names/glob
    /// patterns Hermes writes to `mcp_servers.<name>.tools.exclude` at
    /// install time (everything else stays enabled, including tools the
    /// server adds later). Mutually exclusive with `defaultEnabledTools`.
    public let defaultExcludedTools: [String]

    public var id: String { name }

    public init(
        name: String,
        description: String,
        transport: MCPTransport,
        authKind: AuthKind,
        requiredEnvVars: [String] = [],
        url: String? = nil,
        defaultEnabledTools: [String] = [],
        defaultExcludedTools: [String] = []
    ) {
        self.name = name
        self.description = description
        self.transport = transport
        self.authKind = authKind
        self.requiredEnvVars = requiredEnvVars
        self.url = url
        self.defaultEnabledTools = defaultEnabledTools
        self.defaultExcludedTools = defaultExcludedTools
    }
}

/// Static, verbatim-captured roster of Hermes v0.21.0's (tag `v2026.8.31`)
/// 65 `optional-mcps/*/manifest.yaml` entries. Name/description/transport/
/// auth/tools were read directly from each manifest — see
/// `documents/hermes-v0.21.0-audit-report.md` for the capture session.
/// Hermes's own catalog can add/remove entries between releases; this list
/// is a point-in-time snapshot, not a live fetch. Blender was removed from
/// the upstream catalog before v0.20.4 and stays absent here.
///
/// `transport` mirrors the manifest's `transport.type`, NOT the endpoint
/// path. Three entries (asana / paypal / square) declare `type: http`
/// while their `url` still ends in `/sse` — those are streamable-HTTP
/// endpoints behind an `/sse`-shaped path. `hermes mcp install` writes no
/// `transport:` key for them (Hermes's default is streamable-HTTP), so
/// Scarf must prefill `.http` too: a `transport: sse` entry routes
/// `tools/mcp_tool.py` down the `sse_client` path, which is a different
/// protocol and hard-fails outright when combined with
/// `strict_redirect_headers`. (Atlassian used to be a fourth `/sse` entry;
/// its manifest now points at `/v1/mcp/authv2` — the old `/v1/sse` path
/// was deprecated by Atlassian after June 30, 2026 and 404s.)
///
/// `defaultExcludedTools`/`defaultEnabledTools` mirror the manifest's
/// `tools.default_excluded`/`tools.default_enabled` (mutually exclusive —
/// see `OptionalMCPCatalogEntry`'s doc comments). Scarf's install path
/// writes `defaultExcludedTools` to `mcp_servers.<name>.tools.exclude`,
/// same as `hermes mcp install` does; no capability floor is needed
/// because the config-side `tools.exclude` consumer (`mcp_config.py`,
/// `tools_config.py`) already existed at v0.20.4 (tag `v2026.8.18`) — only
/// the *manifest* key `tools.default_excluded` is new in v0.21.0 (absent
/// even at v2026.8.27/v0.20.6). An older Hermes host given `tools.exclude`
/// config still honors it correctly.
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
            name: "algolia",
            description: "Algolia search: indices, analytics, and settings (read-only).",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.algolia.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "alltrails",
            description: "AllTrails: find hikes and trails with reviews and ratings.",
            transport: .http,
            authKind: .none,
            url: "https://www.alltrails.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "amplitude",
            description: "Amplitude analytics: charts, dashboards, experiments, flags.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.amplitude.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "asana",
            description: "Tasks, projects, and goals from your Asana workspace.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.asana.com/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "atlassian",
            description: "Jira issues and Confluence pages via Atlassian's hosted remote MCP.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.atlassian.com/v1/mcp/authv2"
        ),
        OptionalMCPCatalogEntry(
            name: "attio",
            description: "CRM records, lists, and notes in Attio.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.attio.com/mcp",
            defaultExcludedTools: ["whoami", "query-particle-sql"]
        ),
        OptionalMCPCatalogEntry(
            name: "aws-knowledge",
            description: "Authoritative AWS docs, API references, and best practices.",
            transport: .http,
            authKind: .none,
            url: "https://knowledge-mcp.global.api.aws",
            defaultExcludedTools: ["aws___retrieve_skill"]
        ),
        OptionalMCPCatalogEntry(
            name: "betterstack",
            description: "Better Stack: logs, uptime monitors, incidents, and status pages.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.betterstack.com",
            defaultExcludedTools: ["search_documentation", "Search documentation", "*instructions*", "execute_query", "Execute query", "create_cloud_connection", "Create cloud connection", "*team_member*", "*team member*"]
        ),
        OptionalMCPCatalogEntry(
            name: "buildkite",
            description: "CI/CD pipelines, builds, and test results from Buildkite.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.buildkite.com/mcp",
            defaultExcludedTools: ["access_token", "get_job_env"]
        ),
        OptionalMCPCatalogEntry(
            name: "calendly",
            description: "Scheduling links, events, and invitees from Calendly.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.calendly.com",
            defaultExcludedTools: ["list_calendly_skills", "load_calendly_skill"]
        ),
        OptionalMCPCatalogEntry(
            name: "canva",
            description: "Create, search, and manage Canva designs.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.canva.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "circleci",
            description: "CircleCI: diagnose build failures, read logs, rerun workflows.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.circleci.com/v1/mcp",
            defaultExcludedTools: ["hello", "download_usage_data"]
        ),
        OptionalMCPCatalogEntry(
            name: "clickup",
            description: "Tasks, docs, and workspaces in ClickUp.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.clickup.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "close",
            description: "Sales CRM: leads, opportunities, calls, and emails.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.close.com/mcp",
            defaultExcludedTools: ["close_product_knowledge_search", "customized_builtin_labels", "search", "fetch", "paginate_search", "enrich_field", "schedule_voice_agent_call", "apply_voice_agent_update", "propose_voice_agent_update", "find_voice_agents", "find_agent_configs", "get_voice_agents", "get_voice_agent_overview_report", "get_voice_agent_performance_report"]
        ),
        OptionalMCPCatalogEntry(
            name: "cloudflare",
            description: "Full Cloudflare API access via the official remote MCP.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.cloudflare.com/mcp?codemode=false",
            defaultExcludedTools: ["docs", "*_radar_*", "*_accounts_magic_*", "*_accounts_mnm_*", "*_accounts_cni_*", "*_accounts_teamnet_*", "*_accounts_cloudforceone_*", "*_accounts_dlp_*", "*_accounts_devices*", "*_accounts_dex_*", "*_accounts_datasecurity_*", "*_accounts_emailsecurity_*", "*_accounts_scim_*", "*_accounts_gateway*", "*_accounts_zerotrust_*", "*_accounts_one_*", "*_accounts_brandprotection_*", "*_accounts_intel_*", "*_accounts_urlscanner_*", "*_accounts_vuln_scanner_*", "*_zones_securitycenter_*", "*_accounts_securitycenter_*", "*_zones_api_gateway_*", "*_zones_schema_validation*", "*_zones_token_validation*", "*_zones_waiting_rooms*", "*_accounts_addressing_*", "*_accounts_shares*", "*_accounts_slurper_*", "*_zones_web3_*", "*_accounts_flagship_*", "*_zones_secondary_dns_*", "*_accounts_secondary_dns_*", "*_user_load_balancers*"]
        ),
        OptionalMCPCatalogEntry(
            name: "cloudinary",
            description: "Upload, search, and transform media assets in Cloudinary.",
            transport: .http,
            authKind: .oauth,
            url: "https://asset-management.mcp.cloudinary.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "comfy-cloud",
            description: "Generate images, video, audio, and 3D on Comfy Cloud.",
            transport: .http,
            authKind: .oauth,
            url: "https://cloud.comfy.org/mcp",
            defaultEnabledTools: ["search_templates", "get_template", "get_template_schema", "search_models", "search_nodes", "get_node", "get_prompting_guide", "run_template", "submit_workflow", "partner_generate", "upload_file", "apply_slots", "get_job_status", "wait_for_job", "get_output", "use_previous_output", "cancel_job", "get_queue", "get_billing_status", "get_workflow_canvas_url"]
        ),
        OptionalMCPCatalogEntry(
            name: "context7",
            description: "Up-to-date, version-specific library docs and code examples.",
            transport: .http,
            authKind: .none,
            url: "https://mcp.context7.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "craft",
            description: "Craft: structured docs, tasks, and personal knowledge base.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.craft.do/my/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "datadog",
            description: "Logs, monitors, dashboards, and incidents from Datadog.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.datadoghq.com/api/unstable/mcp-server/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "deepwiki",
            description: "Ask questions about any public GitHub repo (Devin's DeepWiki).",
            transport: .http,
            authKind: .none,
            url: "https://mcp.deepwiki.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "dropbox",
            description: "Search, read, and manage files in Dropbox.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.dropbox.com/mcp",
            defaultExcludedTools: ["GetUsageAndQuota", "CreateFileRequest", "GetFileRequest", "ListFileRequests"]
        ),
        OptionalMCPCatalogEntry(
            name: "figma",
            description: "Official Figma remote MCP — design context, Code Connect, and write-to-canvas via https://mcp.figma.com/mcp (OAuth).",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.figma.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "fireflies",
            description: "Meeting transcripts, summaries, and action items.",
            transport: .http,
            authKind: .oauth,
            url: "https://api.fireflies.ai/mcp",
            defaultExcludedTools: ["fireflies_search", "fireflies_fetch"]
        ),
        OptionalMCPCatalogEntry(
            name: "gamma",
            description: "Gamma: generate and edit AI presentations, docs, and sites.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.gamma.app/mcp",
            defaultExcludedTools: ["get_gamma_viewer_analytics", "get_gamma_viewer_detail_analytics", "get_gamma_card_analytics"]
        ),
        OptionalMCPCatalogEntry(
            name: "gitlab",
            description: "GitLab: issues, merge requests, pipelines, and repo context.",
            transport: .http,
            authKind: .oauth,
            url: "https://gitlab.com/api/v4/mcp",
            defaultExcludedTools: ["get_mcp_server_version", "list_duo_sessions"]
        ),
        OptionalMCPCatalogEntry(
            name: "globalping",
            description: "Ping, traceroute, DNS, and HTTP tests from global probes.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.globalping.dev/mcp",
            defaultExcludedTools: ["help", "compareLocations", "limits"]
        ),
        OptionalMCPCatalogEntry(
            name: "grafana",
            description: "Query metrics, logs, dashboards, alerts, and incidents from Grafana Cloud.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.grafana.com/mcp",
            defaultExcludedTools: ["ask_assistant", "agento11y_*"]
        ),
        OptionalMCPCatalogEntry(
            name: "hugging_face",
            description: "Models, datasets, Spaces, and papers from the Hugging Face Hub.",
            transport: .http,
            authKind: .oauth,
            url: "https://huggingface.co/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "indeed",
            description: "Search jobs and listings on Indeed.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.indeed.com/claude/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "intercom",
            description: "Conversations, tickets, and customer data from Intercom.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.intercom.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "kiwi",
            description: "Kiwi.com flight search: itineraries with direct booking links.",
            transport: .http,
            authKind: .none,
            url: "https://mcp.kiwi.com",
            defaultEnabledTools: ["search-flight"]
        ),
        OptionalMCPCatalogEntry(
            name: "klaviyo",
            description: "Klaviyo marketing: campaigns, flows, segments, and reporting.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.klaviyo.com/mcp?core-tools-only=true&disable-tools-with-user-generated-content=true"
        ),
        OptionalMCPCatalogEntry(
            name: "linear",
            description: "Find, create, and update Linear issues, projects, and comments.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.linear.app/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "microsoft-learn",
            description: "Official Microsoft, Azure, and .NET docs and code samples.",
            transport: .http,
            authKind: .none,
            url: "https://learn.microsoft.com/api/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "miro",
            description: "Read and edit Miro boards, diagrams, and frames.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.miro.com/",
            defaultExcludedTools: ["diagram_create", "diagram_get_dsl", "layout_create", "layout_get_dsl", "layout_read", "layout_update"]
        ),
        OptionalMCPCatalogEntry(
            name: "mixpanel",
            description: "Mixpanel analytics: events, funnels, retention, dashboards.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.mixpanel.com/mcp",
            defaultExcludedTools: ["Get-Experiment-Setup-Guidance", "Get-Experiment-Results-Interpretation-Guidance", "Explain-Experiment-Health-Check", "Run-Experiment-Pre-Launch-Checks", "Get-Feature-Flag-Setup-Guidance", "Get-Feature-Flag-Lifecycle-Guidance", "Display-Query", "Get-Lexicon-URL", "Bulk-Edit-Events", "Bulk-Edit-Properties"]
        ),
        OptionalMCPCatalogEntry(
            name: "monday",
            description: "Boards, items, docs, and workflows in monday.com.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.monday.com/mcp",
            defaultExcludedTools: ["all_monday_api", "get_graphql_schema", "get_type_details", "get_sprint_summary", "create_notification"]
        ),
        OptionalMCPCatalogEntry(
            name: "motherduck",
            description: "MotherDuck: query DuckDB cloud warehouses with SQL.",
            transport: .http,
            authKind: .oauth,
            url: "https://api.motherduck.com/mcp",
            defaultEnabledTools: ["list_columns", "list_databases", "list_macros", "list_shares", "list_tables", "list_views", "query", "query_rw", "search_catalog"]
        ),
        OptionalMCPCatalogEntry(
            name: "n8n",
            description: "Manage and inspect n8n workflows from Hermes (stdio bridge, no public port).",
            transport: .stdio,
            authKind: .apiKey,
            requiredEnvVars: ["N8N_BASE_URL", "N8N_API_KEY"],
            defaultEnabledTools: ["health", "list_workflows", "get_workflow", "find_workflows", "list_executions", "get_execution", "recent_failures", "export_workflow"]
        ),
        OptionalMCPCatalogEntry(
            name: "neon",
            description: "Neon serverless Postgres: projects, branches, and SQL.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.neon.tech/mcp",
            defaultExcludedTools: ["search", "fetch", "list_docs_resources", "get_doc_resource", "query_logs", "list_log_fields", "list_log_field_values", "provision_neon_auth", "configure_neon_auth", "get_neon_auth_config"]
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
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.paypal.com/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "plaid",
            description: "Plaid dashboard: integrations, Items, and usage debugging.",
            transport: .http,
            authKind: .oauth,
            url: "https://api.dashboard.plaid.com/mcp/",
            defaultExcludedTools: ["plaid_get_tools_introduction"]
        ),
        OptionalMCPCatalogEntry(
            name: "postman",
            description: "Postman workspaces, collections, environments, and APIs.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.postman.com/minimal"
        ),
        OptionalMCPCatalogEntry(
            name: "prisma-postgres",
            description: "Create and manage Prisma Postgres databases.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.prisma.io/mcp",
            defaultExcludedTools: ["search_prisma_documentation"]
        ),
        OptionalMCPCatalogEntry(
            name: "railway",
            description: "Railway: projects, services, deployments, and environments.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.railway.com",
            defaultExcludedTools: ["railway-agent"]
        ),
        OptionalMCPCatalogEntry(
            name: "robinhood",
            description: "Robinhood agentic trading: portfolio, balances, and orders.",
            transport: .http,
            authKind: .oauth,
            url: "https://agent.robinhood.com/mcp/trading",
            defaultExcludedTools: ["get_option_level_upgrade_info", "get_popular_watchlists", "follow_watchlist", "unfollow_watchlist"]
        ),
        OptionalMCPCatalogEntry(
            name: "semgrep",
            description: "Scan code for security vulnerabilities with Semgrep.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.semgrep.ai/mcp",
            defaultExcludedTools: ["security_check", "supported_languages", "semgrep_rule_schema"]
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
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.squareup.com/sse"
        ),
        OptionalMCPCatalogEntry(
            name: "strava",
            description: "Strava: activities, fitness trends, training load (read-only).",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.strava.com/mcp"
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
            name: "todoist",
            description: "Manage Todoist tasks and projects.",
            transport: .http,
            authKind: .oauth,
            url: "https://ai.todoist.net/mcp",
            defaultExcludedTools: ["search", "fetch", "export-project-template", "import-project-template"]
        ),
        OptionalMCPCatalogEntry(
            name: "trivago",
            description: "trivago hotel search: compare prices by city and dates.",
            transport: .http,
            authKind: .none,
            url: "https://mcp.trivago.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "twelve-data",
            description: "Stocks, forex, and crypto market data from Twelve Data.",
            transport: .http,
            authKind: .oauth,
            url: "https://mcp.twelvedata.com/mcp",
            defaultExcludedTools: ["oauth_login", "auth_status", "oauth_configure", "get_api_usage"]
        ),
        OptionalMCPCatalogEntry(
            name: "twilio-docs",
            description: "Twilio developer docs search (public beta, read-only).",
            transport: .http,
            authKind: .none,
            url: "https://mcp.twilio.com/docs"
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
        OptionalMCPCatalogEntry(
            name: "wolfram",
            description: "Wolfram|Alpha computation, math, and curated knowledge.",
            transport: .http,
            authKind: .none,
            url: "https://agenttools.wolfram.com/mcp"
        ),
        OptionalMCPCatalogEntry(
            name: "wordpress-com",
            description: "WordPress.com: posts, pages, drafts, stats, and comments.",
            transport: .http,
            authKind: .oauth,
            url: "https://public-api.wordpress.com/wpcom/v2/mcp/v1"
        ),
    ]
}
