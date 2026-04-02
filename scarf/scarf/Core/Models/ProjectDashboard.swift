import Foundation

// MARK: - Registry

struct ProjectRegistry: Codable, Sendable {
    var projects: [ProjectEntry]
}

struct ProjectEntry: Codable, Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let path: String

    var dashboardPath: String { path + "/.scarf/dashboard.json" }
}

// MARK: - Dashboard

struct ProjectDashboard: Codable, Sendable {
    let version: Int
    let title: String
    let description: String?
    let updatedAt: String?
    let theme: DashboardTheme?
    let sections: [DashboardSection]
}

struct DashboardTheme: Codable, Sendable {
    let accent: String?
}

struct DashboardSection: Codable, Sendable, Identifiable {
    var id: String { title }
    let title: String
    let columns: Int?
    let widgets: [DashboardWidget]

    var columnCount: Int { columns ?? 3 }
}

struct DashboardWidget: Codable, Sendable, Identifiable {
    var id: String { type + ":" + title }

    let type: String
    let title: String

    // Stat
    let value: WidgetValue?
    let icon: String?
    let color: String?
    let subtitle: String?

    // Progress
    let label: String?

    // Text
    let content: String?
    let format: String?

    // Table
    let columns: [String]?
    let rows: [[String]]?

    // Chart
    let chartType: String?
    let xLabel: String?
    let yLabel: String?
    let series: [ChartSeries]?

    // List
    let items: [ListItem]?

    // Webview
    let url: String?
    let height: Double?
}

// MARK: - Widget Value (String or Number)

enum WidgetValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)

    var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(n))
                : String(format: "%.1f", n)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                WidgetValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected String or Number")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

// MARK: - Chart Data

struct ChartSeries: Codable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let color: String?
    let data: [ChartDataPoint]
}

struct ChartDataPoint: Codable, Sendable, Identifiable {
    var id: String { x }
    let x: String
    let y: Double
}

// MARK: - List Data

struct ListItem: Codable, Sendable, Identifiable {
    var id: String { text }
    let text: String
    let status: String?
}
