import Foundation

// MARK: - Registry

public struct ProjectRegistry: Codable, Sendable {
    public var projects: [ProjectEntry]

    /// Top-level keys this model doesn't declare, carried through the
    /// round-trip for the same reason `ProjectEntry.extra` is: the file is
    /// agent-writable, and a save must not delete a `schemaVersion` or a
    /// future fleet-wide key just because this build predates it.
    public var extra: [String: JSONValue]

    public init(
        projects: [ProjectEntry],
        extra: [String: JSONValue] = [:]
    ) {
        self.projects = projects
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case projects
    }

    /// Per-row salvage decode. The registry is agent-writable, so one
    /// bad row must never cost the whole file: rows decode
    /// independently and an undecodable one is skipped rather than
    /// thrown. Only a file that isn't a registry at all (no `projects`
    /// array) fails — `ProjectDashboardService` quarantines that case.
    ///
    /// Rows go through `SalvagedRow`, whose `init(from:)` never throws,
    /// so the array decode always advances past a bad element. Decoding
    /// element-by-element off an `UnkeyedDecodingContainer` would not:
    /// a throwing `decode` leaves the container's index untouched.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try c.decode([SalvagedRow].self, forKey: .projects)
        let log = decoder.userInfo[.projectRegistrySalvage] as? RegistrySalvageLog
        for row in rows where row.entry == nil { log?.recordDroppedRow() }
        self.projects = rows.compactMap(\.entry)

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        if let raw = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in raw.allKeys where !known.contains(key.stringValue) {
                if let value = try? raw.decode(JSONValue.self, forKey: key) {
                    extras[key.stringValue] = value
                }
            }
        }
        self.extra = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projects, forKey: .projects)
        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try raw.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }
}

private struct SalvagedRow: Decodable {
    let entry: ProjectEntry?

    init(from decoder: Decoder) throws {
        entry = try? ProjectEntry(from: decoder)
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

    /// Stable per-project UUID — the registry's index into the
    /// first-class `ScarfProject` record (`<path>/.scarf/project.json`)
    /// and the key behind the `[proj:<id>]` cron tag. `nil` for
    /// pre-Phase-1 rows; `ProjectStore` mints + back-fills it on first
    /// migration (additive — old `projects.json` files decode cleanly
    /// as `nil`). It is intentionally **excluded from `Equatable`/
    /// `Hashable`** below: a project's logical identity stays
    /// name+path+folder+archived (what the sidebar selection and sheet
    /// presentation key on), so back-filling the UUID never changes
    /// equality and never disturbs selection highlight.
    public var uuid: UUID?

    /// Every key in this row that `ProjectEntry` does not model, carried
    /// verbatim through decode → edit → encode.
    ///
    /// Without it, ANY save rewrites the whole registry from the model and
    /// silently deletes what the model doesn't declare: a newer Scarf's
    /// field erased by an older build, an agent's own annotation erased by
    /// a rename, the future `bots` binding erased by a folder drag. Same
    /// contract `HermesCronJob.extra` keeps for `cron/jobs.json` and
    /// `saveDashboard` keeps by re-serializing through `JSONSerialization`
    /// — a model round-trip is only safe on a file the model owns, and
    /// `projects.json` is agent-writable by design.
    ///
    /// Excluded from `Equatable`/`Hashable` for the same reason `uuid` is:
    /// logical identity is name+path+folder+archived, and an unknown key
    /// appearing must not disturb sidebar selection.
    public var extra: [String: JSONValue]

    public init(
        name: String,
        path: String,
        folder: String? = nil,
        archived: Bool = false,
        uuid: UUID? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.name = name
        self.path = path
        self.folder = folder
        self.archived = archived
        self.uuid = uuid
        self.extra = extra
    }

    // MARK: - Equatable / Hashable (logical identity, sans `uuid`)
    //
    // Hand-written to EXCLUDE `uuid` so the metadata back-fill is
    // invisible to selection (`selectedProject == project`), sheet
    // presentation, and any set membership. Mirrors the exact field
    // set the compiler synthesized before `uuid` was added.

    public static func == (lhs: ProjectEntry, rhs: ProjectEntry) -> Bool {
        lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.folder == rhs.folder
            && lhs.archived == rhs.archived
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(path)
        hasher.combine(folder)
        hasher.combine(archived)
    }

    public var dashboardPath: String { path + "/.scarf/dashboard.json" }

    /// Directory holding the project's Scarf-managed sidecar files
    /// (dashboard.json, manifest.json, template.lock.json, config.json,
    /// plus any cron-job-written reports the dashboard widgets reference).
    /// Watched as a unit by `HermesFileWatcher` so any file added /
    /// removed / renamed inside refreshes the dashboard automatically.
    public var scarfDir: String { path + "/.scarf" }

    // MARK: - Codable (custom for backward compat)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name, path, folder, archived, uuid
    }

    /// `name` + `path` are the row: without them there is no project,
    /// so they still throw (the row is then skipped by
    /// `ProjectRegistry`). Every OPTIONAL field decodes leniently — a
    /// malformed value drops that FIELD, never the row. The live
    /// 2026-09-02 corruption was a hand-written `"uuid":
    /// "SHABUBOX-SEO-TRACKER-2026-09-03"`; an agent mistyping one key
    /// must not be able to erase a project, let alone every project.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)

        let log = decoder.userInfo[.projectRegistrySalvage] as? RegistrySalvageLog
        let row = name
        func salvage<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            if let value = try? c.decodeIfPresent(type, forKey: key) { return value }
            // Absent or explicitly null is normal; anything else was a
            // value we could not read and are dropping.
            if c.contains(key), !((try? c.decodeNil(forKey: key)) ?? false) {
                log?.recordSalvagedField(key.stringValue, row: row)
            }
            return nil
        }
        self.folder = salvage(String.self, .folder)
        self.archived = salvage(Bool.self, .archived) ?? false
        self.uuid = salvage(UUID.self, .uuid)

        // Sweep up every key this model doesn't declare — explicit nulls
        // included — so `encode(to:)` puts them back untouched. A key whose
        // VALUE won't even decode as JSON is impossible from a JSONDecoder
        // (every JSON value is a `JSONValue`), so nothing is silently lost
        // here; a key we can't read at all is recorded as salvage.
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        if let raw = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in raw.allKeys where !known.contains(key.stringValue) {
                if let value = try? raw.decode(JSONValue.self, forKey: key) {
                    extras[key.stringValue] = value
                } else {
                    log?.recordSalvagedField(key.stringValue, row: row)
                }
            }
        }
        self.extra = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(folder, forKey: .folder)
        if archived {
            try c.encode(archived, forKey: .archived)
        }
        try c.encodeIfPresent(uuid, forKey: .uuid)

        // Unknown keys go back last. They cannot collide with the declared
        // ones (they were filtered against exactly this key set on the way
        // in), so this never overwrites a modelled field.
        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try raw.encode(value, forKey: AnyCodingKey(stringValue: key))
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
    /// Columns to lay the section's widgets out in, CLAMPED on the read
    /// path.
    ///
    /// `dashboard.json` is agent-written, and both renderers hand this
    /// straight to a grid: SwiftUI's `LazyVGrid` traps on a zero/negative
    /// column count (confirmed SIGTRAP), and a four-figure count builds
    /// thousands of empty grid items. Clamping HERE rather than in each
    /// renderer means the validator, the Mac view and the iOS view can
    /// never disagree — and a section that was going to crash the app
    /// merely looks wrong instead. 12 is the ceiling because a dashboard
    /// section wider than that is unreadable at any window size.
    public var columnCount: Int { min(max(columns ?? 3, 1), 12) }
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

    // Webview / Image (image reuses `url` for remote, `path` for local)
    public let url: String?
    public let height: Double?

    // v2.7 — file-reading widgets (markdown_file, log_tail, image-local).
    // `path` is resolved relative to the project root (the directory that
    // contains `.scarf/`). Renderers must reject `..` segments after
    // normalization to prevent escape from the project boundary.
    public let path: String?
    public let lines: Int?

    // v2.7 — cron_status widget; `jobId` matches HermesCronJob.id.
    public let jobId: String?

    // v2.7 — status_grid widget; `cells` carries label + status per square,
    // `gridColumns` overrides the auto-fit column count (keep distinct
    // from `columns` which is the table-widget header list).
    public let cells: [StatusGridCell]?
    public let gridColumns: Int?

    // v2.7 — optional sparkline trend on `stat` widgets.
    public let sparkline: [Double]?

    public init(
        type: String,
        title: String,
        value: WidgetValue? = nil,
        icon: String? = nil,
        color: String? = nil,
        subtitle: String? = nil,
        label: String? = nil,
        content: String? = nil,
        format: String? = nil,
        columns: [String]? = nil,
        rows: [[String]]? = nil,
        chartType: String? = nil,
        xLabel: String? = nil,
        yLabel: String? = nil,
        series: [ChartSeries]? = nil,
        items: [ListItem]? = nil,
        url: String? = nil,
        height: Double? = nil,
        path: String? = nil,
        lines: Int? = nil,
        jobId: String? = nil,
        cells: [StatusGridCell]? = nil,
        gridColumns: Int? = nil,
        sparkline: [Double]? = nil
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
        self.path = path
        self.lines = lines
        self.jobId = jobId
        self.cells = cells
        self.gridColumns = gridColumns
        self.sparkline = sparkline
    }
}

// MARK: - Status Grid Data (v2.7)

/// One cell of a `status_grid` widget. Status semantics match `ListItem.status`
/// — parsed via `ListItemStatus(raw:)` so the same vocabulary + synonyms apply.
public struct StatusGridCell: Codable, Sendable, Identifiable, Hashable {
    public var id: String { label }
    public let label: String
    public let status: String?
    public let tooltip: String?

    public init(label: String, status: String? = nil, tooltip: String? = nil) {
        self.label = label
        self.status = status
        self.tooltip = tooltip
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

/// Typed semantic status for `ListItem` (and `status_grid` cells in v2.7+).
///
/// Wire format stays a free `String?` on `ListItem` for backwards compatibility —
/// pre-existing dashboards never break. Renderers call `ListItemStatus(raw:)`
/// to map known values + synonyms to a canonical case; unknown values return
/// `nil` and render as plain neutral text.
public enum ListItemStatus: String, Sendable, Hashable, CaseIterable {
    case success
    case warning
    case danger
    case info
    case pending
    case done
    case neutral

    /// Lenient parse — accepts canonical names plus common synonyms seen in
    /// real-world dashboards (`ok`/`up` → success, `down`/`error`/`failed` →
    /// danger, `active` → info). Returns `nil` for unrecognized strings so
    /// the renderer can fall back to plain text.
    public init?(raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "success", "ok", "up", "green", "passing":
            self = .success
        case "warning", "warn", "yellow", "degraded":
            self = .warning
        case "danger", "down", "error", "failed", "failure", "red", "critical":
            self = .danger
        case "info", "active", "blue":
            self = .info
        case "pending", "queued", "waiting", "scheduled":
            self = .pending
        case "done", "complete", "completed", "finished":
            self = .done
        case "neutral", "muted", "gray":
            self = .neutral
        default:
            return nil
        }
    }
}
