import Foundation

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
    case skills = "Skills"
    // Configure (Phase 2/3 additions)
    case platforms = "Platforms"
    case personalities = "Personalities"
    case quickCommands = "Quick Commands"
    case credentialPools = "Credential Pools"
    case plugins = "Plugins"
    case webhooks = "Webhooks"
    case profiles = "Profiles"
    // Manage
    case tools = "Tools"
    case mcpServers = "MCP Servers"
    case gateway = "Gateway"
    case cron = "Cron"
    case health = "Health"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .insights: return "chart.bar"
        case .sessions: return "bubble.left.and.bubble.right"
        case .activity: return "bolt.horizontal"
        case .projects: return "square.grid.2x2"
        case .chat: return "text.bubble"
        case .memory: return "brain"
        case .skills: return "lightbulb"
        case .platforms: return "dot.radiowaves.left.and.right"
        case .personalities: return "theatermasks"
        case .quickCommands: return "command.square"
        case .credentialPools: return "key.horizontal"
        case .plugins: return "app.badge.checkmark"
        case .webhooks: return "arrow.up.right.square"
        case .profiles: return "person.2.crop.square.stack"
        case .tools: return "wrench.and.screwdriver"
        case .mcpServers: return "puzzlepiece.extension"
        case .gateway: return "antenna.radiowaves.left.and.right"
        case .cron: return "clock.arrow.2.circlepath"
        case .health: return "stethoscope"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

@Observable
final class AppCoordinator {
    var selectedSection: SidebarSection = .dashboard
    var selectedSessionId: String?
    var selectedProjectName: String?
}
