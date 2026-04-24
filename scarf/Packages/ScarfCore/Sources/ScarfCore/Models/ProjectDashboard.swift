import Foundation

// MARK: - Registry

public struct ProjectRegistry: Codable, Sendable {
    public var projects: [ProjectEntry]

    public init(
        projects: [ProjectEntry]
    ) {
        self.projects = projects
    }
}

public struct ProjectEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let path: String

    /// Folder path for sidebar grouping. `nil` means top-level.
    /// v2.3 registry schema v2; v2.2 files decode cleanly as `nil`.
    public var folder: String?

    /// Soft-archive flag. Archived projects are hidden from the sidebar
    /// by default; non-destructive. v2.3 schema v2; defaults to `false`.
    public var archived: Bool

    public init(
        name: String,
        path: String,
        folder: String? = nil,
        archived: Bool = false
    ) {
        self.name = name
        self.path = path
        self.folder = folder
        self.archived = archived
    }

    public var dashboardPath: String { path + "/.scarf/dashboard.json" }

    // MARK: - Codable (custom for backward compat)

    private enum CodingKeys: String, CodingKey {
        case name, path, folder, archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)
        self.folder = try c.decodeIfPresent(String.self, forKey: .folder)
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(folder, forKey: .folder)
        if archived {
            try c.encode(archived, forKey: .archived)
        }
    }
}

// MARK: - Dashboard

public struct ProjectDashboard: Codable, Sendable {
    public let version: Int
    public let title: String
    public let description: String?
    public let updatedAt: String?
    public let theme: DashboardTheme?
    public let sections: [DashboardSection]

    public init(
        version: Int,
        title: String,
        description: String?,
        updatedAt: String?,
        theme: DashboardTheme?,
        sections: [DashboardSection]
    ) {
        self.version = version
        self.title = title
        self.description = description
        self.updatedAt = updatedAt
        self.theme = theme
        self.sections = sections
    }
}

public struct DashboardTheme: Codable, Sendable {
    public let accent: String?

    public init(
        accent: String?
    ) {
        self.accent = accent
    }
}

public struct DashboardSection: Codable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let columns: Int?
    public let widgets: [DashboardWidget]


    public init(
        title: String,
        columns: Int?,
        widgets: [DashboardWidget]
    ) {
        self.title = title
        self.columns = columns
        self.widgets = widgets
    }
    public var columnCount: Int { columns ?? 3 }
}

public struct DashboardWidget: Codable, Sendable, Identifiable {
    public var id: String { type + ":" + title }

    public let type: String
    public let title: String

    // Stat
    public let value: WidgetValue?
    public let icon: String?
    public let color: String?
    public let subtitle: String?

    // Progress
    public let label: String?

    // Text
    public let content: String?
    public let format: String?

    // Table
    public let columns: [String]?
    public let rows: [[String]]?

    // Chart
    public let chartType: String?
    public let xLabel: String?
    public let yLabel: String?
    public let series: [ChartSeries]?

    // List
    public let items: [ListItem]?

    // Webview
    public let url: String?
    public let height: Double?

    public init(
        type: String,
        title: String,
        value: WidgetValue?,
        icon: String?,
        color: String?,
        subtitle: String?,
        label: String?,
        content: String?,
        format: String?,
        columns: [String]?,
        rows: [[String]]?,
        chartType: String?,
        xLabel: String?,
        yLabel: String?,
        series: [ChartSeries]?,
        items: [ListItem]?,
        url: String?,
        height: Double?
    ) {
        self.type = type
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
        self.subtitle = subtitle
        self.label = label
        self.content = content
        self.format = format
        self.columns = columns
        self.rows = rows
        self.chartType = chartType
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.series = series
        self.items = items
        self.url = url
        self.height = height
    }
}

// MARK: - Widget Value (String or Number)

public enum WidgetValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)

    public var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0
                ? Int(n).formatted(.number)
                : n.formatted(.number.precision(.fractionLength(1)))
        }
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

// MARK: - Chart Data

public struct ChartSeries: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let color: String?
    public let data: [ChartDataPoint]

    public init(
        name: String,
        color: String?,
        data: [ChartDataPoint]
    ) {
        self.name = name
        self.color = color
        self.data = data
    }
}

public struct ChartDataPoint: Codable, Sendable, Identifiable {
    public var id: String { x }
    public let x: String
    public let y: Double

    public init(
        x: String,
        y: Double
    ) {
        self.x = x
        self.y = y
    }
}

// MARK: - List Data

public struct ListItem: Codable, Sendable, Identifiable {
    public var id: String { text }
    public let text: String
    public let status: String?

    public init(
        text: String,
        status: String?
    ) {
        self.text = text
        self.status = status
    }
}
