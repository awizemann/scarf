import Foundation

// MARK: - Registry

struct ProjectRegistry: Codable, Sendable {
    var projects: [ProjectEntry]
}

struct ProjectEntry: Codable, Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let path: String

    /// Folder path for sidebar grouping. `nil` means top-level (no
    /// folder). Introduced in v2.3 — v2.2 registry files have no
    /// `folder` key, which decodes cleanly as `nil` via
    /// `decodeIfPresent` below.
    ///
    /// We leave shape flexible: today this is treated as an opaque
    /// single-level label (e.g. "Clients"), and the sidebar renders
    /// one DisclosureGroup per distinct value. If nesting becomes a
    /// requirement later, we can interpret the string as a slash-
    /// separated path without a migration (old single-label values
    /// still mean a top-level folder with that name).
    var folder: String?

    /// Soft-archive flag. Archived projects are hidden from the
    /// sidebar by default; a Show Archived toggle surfaces them.
    /// Non-destructive — nothing is deleted on disk. Introduced in
    /// v2.3; v2.2 registry files default to `false` via the custom
    /// decoder below.
    var archived: Bool

    var dashboardPath: String { path + "/.scarf/dashboard.json" }

    init(name: String, path: String, folder: String? = nil, archived: Bool = false) {
        self.name = name
        self.path = path
        self.folder = folder
        self.archived = archived
    }

    // MARK: - Codable (custom for backward compat)

    private enum CodingKeys: String, CodingKey {
        case name, path, folder, archived
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)
        // Both new fields: tolerate absence for v2.2-era registries.
        self.folder = try c.decodeIfPresent(String.self, forKey: .folder)
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        // Only emit optional fields when they carry meaning — keeps
        // registry files clean for the common (top-level, unarchived)
        // case and means v2.2 Scarf can still load a v2.3-written
        // registry of projects that never used the new features.
        try c.encodeIfPresent(folder, forKey: .folder)
        if archived {
            try c.encode(archived, forKey: .archived)
        }
    }
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
                ? Int(n).formatted(.number)
                : n.formatted(.number.precision(.fractionLength(1)))
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
