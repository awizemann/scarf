import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case insights = "Insights"
    case sessions = "Sessions"
    case activity = "Activity"
    case chat = "Chat"
    case memory = "Memory"
    case skills = "Skills"
    case tools = "Tools"
    case gateway = "Gateway"
    case cron = "Cron"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .insights: return "chart.bar"
        case .sessions: return "bubble.left.and.bubble.right"
        case .activity: return "bolt.horizontal"
        case .chat: return "text.bubble"
        case .memory: return "brain"
        case .skills: return "lightbulb"
        case .tools: return "wrench.and.screwdriver"
        case .gateway: return "antenna.radiowaves.left.and.right"
        case .cron: return "clock.arrow.2.circlepath"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

@Observable
final class AppCoordinator {
    var selectedSection: SidebarSection = .dashboard
    var selectedSessionId: String?
}
