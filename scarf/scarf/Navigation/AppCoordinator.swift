import Foundation
import ScarfCore

enum SidebarSection: String, CaseIterable, Identifiable {
    // Monitor
    case dashboard = "Dashboard"
    case insights = "Insights"
    case sessions = "Sessions"
    case activity = "Activity"
    // Projects
    case projects = "Projects"
    // Interact
    case chat = "Chat"
    case memory = "Memory"
    case curator = "Curator"
    case skills = "Skills"
    // Configure (Phase 2/3 additions)
    case platforms = "Platforms"
    case personalities = "Personalities"
    case quickCommands = "Quick Commands"
    case credentialPools = "Credential Pools"
    case plugins = "Plugins"
    case webhooks = "Webhooks"
    case profiles = "Profiles"
    case models = "Models"
    /// Hermes v0.14 — OpenAI-compatible local proxy that forwards
    /// requests with the user's OAuth-authed provider credentials.
    /// Listed under Configure between Models and Profiles since it
    /// configures how third-party tools (Codex, Aider, Cline) reach
    /// the user's Hermes-managed subscription.
    case proxy = "Proxy"
    // Manage
    case tools = "Tools"
    case mcpServers = "MCP Servers"
    case gateway = "Gateway"
    case cron = "Cron"
    case kanban = "Kanban"
    case health = "Health"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .dashboard: return "Dashboard"
        case .insights: return "Insights"
        case .sessions: return "Sessions"
        case .activity: return "Activity"
        case .projects: return "Projects"
        case .chat: return "Chat"
        case .memory: return "Memory"
        case .curator: return "Curator"
        case .skills: return "Skills"
        case .platforms: return "Platforms"
        case .personalities: return "Personalities"
        case .quickCommands: return "Quick Commands"
        case .credentialPools: return "Credential Pools"
        case .plugins: return "Plugins"
        case .webhooks: return "Webhooks"
        case .profiles: return "Profiles"
        case .models: return "Models"
        case .proxy: return "Hermes Proxy"
        case .tools: return "Tools"
        case .mcpServers: return "MCP Servers"
        case .gateway: return "Messaging Gateway"
        case .cron: return "Cron"
        case .kanban: return "Kanban"
        case .health: return "Health"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    /// Stable snake_case token for the `section` prop on `section_viewed`.
    ///
    /// Deliberately *not* `rawValue`/`displayName`: those are user-facing
    /// copy, and renaming a sidebar item ("Quick Commands" → "Shortcuts")
    /// would silently split one section's history into two series. This
    /// switch is the analytics vocabulary and is used for nothing else —
    /// changing a case here is a taxonomy change, not a UI change.
    var analyticsToken: String {
        switch self {
        case .dashboard: return "dashboard"
        case .insights: return "insights"
        case .sessions: return "sessions"
        case .activity: return "activity"
        case .projects: return "projects"
        case .chat: return "chat"
        case .memory: return "memory"
        case .curator: return "curator"
        case .skills: return "skills"
        case .platforms: return "platforms"
        case .personalities: return "personalities"
        case .quickCommands: return "quick_commands"
        case .credentialPools: return "credential_pools"
        case .plugins: return "plugins"
        case .webhooks: return "webhooks"
        case .profiles: return "profiles"
        case .models: return "models"
        case .proxy: return "proxy"
        case .tools: return "tools"
        case .mcpServers: return "mcp_servers"
        case .gateway: return "gateway"
        case .cron: return "cron"
        case .kanban: return "kanban"
        case .health: return "health"
        case .logs: return "logs"
        case .settings: return "settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .insights: return "chart.bar"
        case .sessions: return "bubble.left.and.bubble.right"
        case .activity: return "bolt.horizontal"
        case .projects: return "square.grid.2x2"
        case .chat: return "text.bubble"
        case .memory: return "brain"
        case .curator: return "sparkles"
        case .skills: return "lightbulb"
        case .platforms: return "dot.radiowaves.left.and.right"
        case .personalities: return "theatermasks"
        case .quickCommands: return "command.square"
        case .credentialPools: return "key.horizontal"
        case .plugins: return "app.badge.checkmark"
        case .webhooks: return "arrow.up.right.square"
        case .profiles: return "person.2.crop.square.stack"
        case .models: return "cpu"
        case .proxy: return "shippingbox.and.arrow.backward"
        case .tools: return "wrench.and.screwdriver"
        case .mcpServers: return "puzzlepiece.extension"
        case .gateway: return "antenna.radiowaves.left.and.right"
        case .cron: return "clock.arrow.2.circlepath"
        case .kanban: return "rectangle.split.3x1"
        case .health: return "stethoscope"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

@Observable
final class AppCoordinator {
    var selectedSection: SidebarSection = .dashboard {
        didSet { Self.recordSectionViewed(selectedSection) }
    }

    /// Every window starts on `.dashboard`, but a property initializer's
    /// default value never runs `didSet` — so without this the very first
    /// section a user sees would never be recorded.
    init() {
        Self.recordSectionViewed(selectedSection)
    }

    /// Report `section_viewed` once per section per app *process*.
    ///
    /// The dedupe lives in `Analytics.recordOnce`, not in an instance
    /// property, because `AppCoordinator` is per-window: `ContextBoundRoot`
    /// builds a fresh one for every window and rebuilds it on every
    /// server/profile switch, and each new coordinator's `init` re-reports
    /// `.dashboard`. An instance-scoped `Set` therefore deduped only within
    /// one window's lifetime and inflated the event several times per
    /// session.
    ///
    /// Still one funnel point rather than a guard at each call site: sidebar
    /// taps, programmatic hand-offs (kanban, credential re-auth, the settings
    /// command) and re-selecting the current section all assign
    /// `selectedSection`.
    static func recordSectionViewed(_ section: SidebarSection) {
        let token = section.analyticsToken
        Analytics.recordOnce("section_viewed", key: "section_viewed:\(token)", props: ["section": token])
    }

    var selectedSessionId: String?
    var selectedProjectName: String?

    /// When non-nil, ChatView should start a fresh ACP session with
    /// this absolute project path as cwd and then clear the value.
    /// Wired from the per-project Sessions tab's "New Chat" button
    /// (v2.3): the tab sets this, switches `selectedSection` to
    /// `.chat`, and ChatView reacts on its next render.
    ///
    /// Separate from `selectedSessionId` (which resumes an existing
    /// session) — a new session needs a cwd override Scarf doesn't
    /// yet have an id for.
    var pendingProjectChat: String?

    /// Optional first message to send automatically once a
    /// `pendingProjectChat` session has connected. Set alongside
    /// `pendingProjectChat` by the "New Project from Scratch" wizard
    /// (v2.8) so the agent receives a kickoff prompt that activates
    /// the `scarf-template-author` skill without the user having to
    /// type one. Sister slot to `pendingProjectChat`: ChatView consumes
    /// both in lockstep and clears them. Nil for plain "open project
    /// chat" handoffs (the Sessions tab's "New Chat" button).
    var pendingInitialPrompt: String?

    /// Lowercase OAuth provider name to re-authenticate. Set by the
    /// chat error banner's "Re-authenticate" button, consumed by
    /// CredentialPoolsView, which auto-presents the OAuth sheet seeded
    /// to this provider. Cleared by the consumer once handled. Sister
    /// of `pendingProjectChat` — a hand-off slot, not a long-lived
    /// state value.
    var pendingOAuthReauth: String?

    /// Hand-off from the chat surface to the global Kanban surface.
    /// Set by `SessionInfoBar`'s Kanban chip, consumed by `KanbanView`
    /// on its next render, which builds a `KanbanBoardView` scoped to the
    /// chat's ACP `sessionId` (with the project tenant available for the
    /// "All project tasks" toggle). Cleared after consumption so a sidebar
    /// return to the same Kanban surface doesn't re-apply a stale scope.
    var pendingKanbanHandoff: KanbanHandoff?

    // MARK: - Project upgrade (one-click → chat enrichment)

    /// Run the deterministic "Upgrade Project" structure pass on an existing
    /// project, then hand off to chat where the agent enriches it (a real
    /// dashboard, slash commands, cron, a starter mini-app) via the
    /// scarf-template-author + scarf-miniapp-author skills. Mirrors the New
    /// Project wizard's scaffold → chat hand-off. The structure pass + skill
    /// bootstrap run off-main; a hard failure there aborts the hand-off (the
    /// service logs it). Idempotent — safe to invoke on an already-upgraded
    /// project (re-enriches).
    /// Project paths with an upgrade in flight — guards against a
    /// double-tap (banner + context menu) kicking off two structure passes
    /// and two chat hand-offs for the same project. Observable so the
    /// banner can disable its button while running.
    private(set) var upgradingProjectPaths: Set<String> = []

    /// Whether an upgrade is currently running for `path`.
    func isUpgrading(_ path: String) -> Bool { upgradingProjectPaths.contains(path) }

    @MainActor
    func upgradeProject(_ project: ProjectEntry, context: ServerContext, hasKanban: Bool) async {
        guard !upgradingProjectPaths.contains(project.path) else { return }
        upgradingProjectPaths.insert(project.path)
        defer { upgradingProjectPaths.remove(project.path) }

        let outcome = await Task.detached(priority: .userInitiated) { () -> ProjectUpgradeService.Outcome? in
            // Ensure the agent will recognize the authoring skills on its
            // next session/new (no-op when already installed + current).
            try? SkillBootstrapService(context: context).ensureBundledSkillsInstalled()
            return try? ProjectUpgradeService(context: context).upgrade(project, hasKanban: hasKanban)
        }.value
        // A nil outcome means the foundational identity write failed (rare:
        // read-only dir, full disk, dead transport). We don't hand off; the
        // cockpit banner stays (provenance wasn't stamped → needsUpgrade
        // remains true), so the user can retry. The service logged the cause.
        guard let outcome else { return }

        pendingProjectChat = project.path
        pendingInitialPrompt = Self.upgradeEnrichmentPrompt(project: project, board: outcome.board)
        selectedSection = .chat
    }

    /// Structured kickoff prompt that drops the agent straight into the
    /// `scarf-template-author` skill in ENRICH mode — same `SKILL:`
    /// invocation convention as the New Project prompt so the agent treats
    /// it as the next action, not a suggestion.
    nonisolated static func upgradeEnrichmentPrompt(project: ProjectEntry, board: String?) -> String {
        let boardLine = board.map { "It now has the Kanban board `\($0)`. " } ?? ""
        return """
        SKILL: scarf-template-author
        PROJECT_PATH: \(project.path)
        PROJECT_NAME: \(project.name)

        This is an EXISTING Scarf project that Scarf just upgraded to the first-class structure — stable id, a managed AGENTS.md block, and a placeholder dashboard. \(boardLine)Run the scarf-template-author skill in ENRICH mode (do NOT re-scaffold, do NOT clobber my files):

        1. Read the project first (README, source, existing .scarf/ files, the placeholder dashboard) to understand what it is.
        2. Replace the placeholder dashboard.json with a real dashboard tailored to this project (widget catalog in the skill). Keep any real widgets I already had.
        3. Add useful slash commands and any helpful cron jobs (created paused).
        4. Build a starter mini-app or two — use the scarf-miniapp-author skill for the bridge contract and the .scarf/miniapps/<id>/ format. Prefer non-sensitive permissions so it runs immediately.

        Enrich in place; only add or replace the placeholder. Start now.

        SKILL: scarf-template-author
        """
    }

    // MARK: - Mini-app presentation

    /// The mini-app currently shown in the cockpit's slide-in **inspector**
    /// (window-level, so it spans the app chrome). Set by the cockpit
    /// Mini-apps panel's "Open" button; `ContentView` binds `.inspector` to
    /// it. **One at a time** — each open mini-app spins up its own dedicated
    /// `hermes acp` process, so single-presentation avoids process
    /// proliferation. ("Open in a separate window" for multiples is a future
    /// additive affordance.)
    var presentedMiniApp: PresentedMiniApp?

    /// A mini-app + the project it belongs to, for the inspector host.
    struct PresentedMiniApp: Identifiable {
        let project: ScarfProject
        let manifest: MiniAppManifest
        var id: String { project.id.uuidString + ":" + manifest.id }
    }

    // MARK: - Feature view-model cache (t-aud24)

    /// Per-window, per-server cache of feature view models.
    ///
    /// `ContentView`'s detail `switch` produces a *different view type per
    /// section*, so SwiftUI tears down + recreates the section view on every
    /// sidebar switch — which re-ran each VM's remote `load()` over SSH on
    /// every re-entry. Caching the VM here lets it (and its already-loaded
    /// data) survive section switches; the VM's `load()` then guards on a
    /// freshness token so re-entry is a no-op instead of a re-fetch.
    ///
    /// Scope is correct for free: this coordinator lives inside
    /// `ContextBoundRoot`, which is keyed `.id(context.id)`, so the whole
    /// coordinator — and this cache — is recreated when the window's server
    /// changes, and each window owns its own coordinator. No per-server
    /// invalidation needed. `@ObservationIgnored` so cache mutation never
    /// trips a view-update cycle.
    @ObservationIgnored private var featureViewModels: [SidebarSection: AnyObject] = [:]

    /// Returns the cached view model for `section`, building + caching one
    /// via `make()` on first request. The returned instance is stable across
    /// section switches for the life of this window/server.
    func featureViewModel<VM: AnyObject>(
        for section: SidebarSection,
        make: () -> VM
    ) -> VM {
        if let existing = featureViewModels[section] as? VM {
            return existing
        }
        let created = make()
        featureViewModels[section] = created
        return created
    }
}

/// Snapshot of "where did this Kanban view come from?" passed across
/// the AppCoordinator hand-off. The destination view consumes the
/// fields at most once. `tenant` is the project's `scarf:<slug>` slug
/// when the chat is project-scoped; nil for global chats. `projectPath`
/// + `projectName` drive the create-sheet workspace defaults +
/// subtitle, and `tenant` backs the board's "All project tasks" scope
/// toggle. `sessionId` is the originating ACP chat session id — the
/// board scopes precisely to it via `hermes kanban list --session`.
/// Non-optional because the chat-header Kanban chip only renders on
/// v0.15+ hosts (gated on `hasKanbanSessionFilter`), where a live
/// session id is always present.
struct KanbanHandoff: Equatable {
    let tenant: String?
    let projectPath: String?
    let projectName: String?
    let sessionId: String
}
