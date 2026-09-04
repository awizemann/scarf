import Foundation

/// The dashboard widget vocabulary, in Swift.
///
/// `tools/widget-schema.json` has been the canonical list since v2.2, but
/// it is a REPO file: the shipped app cannot read it, so nothing could
/// check a `dashboard.json` before it landed on disk. The renderer's
/// `switch widget.type` (ProjectsView `WidgetView`) discovers an unknown
/// type only at paint time, as an "Unknown widget type" placeholder —
/// which is the right behaviour for a file somebody else already wrote,
/// and useless as a gate for a file Scarf is about to write itself.
///
/// This is that gate. It mirrors `tools/widget-schema.json` exactly and
/// is the whitelist `project_update_dashboard` validates against, so an
/// agent gets a precise error back instead of a dashboard that renders as
/// a row of placeholders.
///
/// **Adding a widget type** — the order in `tools/widget-schema.json`'s
/// comment still holds, with one step inserted: schema JSON first, then
/// THIS table, then the Swift view, then `site/widgets.js`, then the
/// skill's Widget Catalog section. Renaming or removing a type breaks
/// every `dashboard.json` that uses it.
public enum DashboardWidgetCatalog {

    /// One widget type's contract: which fields it cannot render without.
    public struct Spec: Sendable {
        public let type: String
        /// Fields that must be present and non-null. `title` is required
        /// by every type and lives in the model, so it is omitted here.
        public let required: [String]
        /// Fields where AT LEAST ONE must be present (the `image`
        /// widget's `path` / `url` pair). Empty for every other type.
        public let requiresOneOf: [String]

        public init(type: String, required: [String], requiresOneOf: [String] = []) {
            self.type = type
            self.required = required
            self.requiresOneOf = requiresOneOf
        }
    }

    /// Mirrors `tools/widget-schema.json` (schemaVersion 1). Keep sorted
    /// by the order that file lists them, so a diff of the two reads
    /// straight down.
    public static let specs: [Spec] = [
        Spec(type: "stat", required: []),
        Spec(type: "progress", required: ["value"]),
        Spec(type: "text", required: ["content"]),
        Spec(type: "table", required: ["columns", "rows"]),
        Spec(type: "chart", required: ["series"]),
        Spec(type: "list", required: ["items"]),
        Spec(type: "webview", required: ["url"]),
        Spec(type: "markdown_file", required: ["path"]),
        Spec(type: "log_tail", required: ["path"]),
        Spec(type: "cron_status", required: ["jobId"]),
        Spec(type: "image", required: [], requiresOneOf: ["path", "url"]),
        Spec(type: "status_grid", required: ["cells"]),
        Spec(type: "kanban_summary", required: []),
    ]

    public static let knownTypes: Set<String> = Set(specs.map(\.type))

    public static func spec(for type: String) -> Spec? {
        specs.first { $0.type == type }
    }

    /// Every problem with a decoded dashboard, as agent-readable lines
    /// addressed by JSON path (`sections[0].widgets[2].type`). Empty
    /// means the dashboard is renderable.
    ///
    /// Structural errors (a missing `title`, a `sections` that isn't an
    /// array) are NOT checked here — `ProjectDashboard`'s decode already
    /// rejects those, and this runs on the decoded value.
    public static func validate(_ dashboard: ProjectDashboard) -> [String] {
        var problems: [String] = []

        if dashboard.version <= 0 {
            problems.append("version: must be a positive integer (got \(dashboard.version))")
        }
        if dashboard.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("title: must not be empty")
        }

        for (s, section) in dashboard.sections.enumerated() {
            let sectionPath = "sections[\(s)]"
            if section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("\(sectionPath).title: must not be empty")
            }
            if let columns = section.columns, columns < 1 || columns > 12 {
                problems.append("\(sectionPath).columns: must be 1...12 (got \(columns))")
            }
            for (w, widget) in section.widgets.enumerated() {
                problems.append(
                    contentsOf: validate(widget, at: "\(sectionPath).widgets[\(w)]")
                )
            }
        }
        return problems
    }

    private static func validate(_ widget: DashboardWidget, at path: String) -> [String] {
        var problems: [String] = []

        guard let spec = spec(for: widget.type) else {
            problems.append(
                "\(path).type: unknown widget type \"\(widget.type)\". "
                    + "Known types: \(specs.map(\.type).joined(separator: ", "))."
            )
            return problems
        }

        if widget.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("\(path).title: must not be empty")
        }

        for field in spec.required where !isPresent(field, on: widget) {
            problems.append("\(path).\(field): required by widget type \"\(widget.type)\"")
        }

        if !spec.requiresOneOf.isEmpty,
           !spec.requiresOneOf.contains(where: { isPresent($0, on: widget) }) {
            problems.append(
                "\(path): widget type \"\(widget.type)\" needs one of "
                    + spec.requiresOneOf.map { "\"\($0)\"" }.joined(separator: " or ")
            )
        }

        // Path-bearing widgets resolve against the project root; the
        // renderers reject `..` after normalization, so a dashboard
        // carrying one would write fine and render as an error. Catch
        // it at the door instead.
        if let p = widget.path, escapesProjectRoot(p) {
            problems.append(
                "\(path).path: must stay inside the project (no absolute paths, no \"..\" segments)"
            )
        }

        // `url` is the OTHER path-carrying field: a `webview` or `image`
        // pointing at `file:///Users/…/.ssh/id_rsa` would pass a check
        // that only looked at `path`, and the renderer would happily load
        // it. Remote widgets take remote URLs.
        if let url = widget.url, !url.isEmpty {
            let scheme = url.prefix { $0 != ":" }.lowercased()
            let allowed = ["http", "https"]
            if !allowed.contains(scheme) {
                problems.append(
                    "\(path).url: must be an http:// or https:// URL"
                        + " (use \"path\" for a file inside the project)"
                )
            }
        }

        return problems
    }

    /// Whether the widget carries a usable value for a schema field name.
    /// A present-but-empty collection counts as missing: a `table` with
    /// no columns renders as nothing, which is the failure the agent
    /// wanted to be told about.
    private static func isPresent(_ field: String, on widget: DashboardWidget) -> Bool {
        switch field {
        case "value": return widget.value != nil
        case "content": return widget.content?.isEmpty == false
        case "columns": return widget.columns?.isEmpty == false
        case "rows": return widget.rows != nil
        case "series": return widget.series?.isEmpty == false
        case "items": return widget.items != nil
        case "url": return widget.url?.isEmpty == false
        case "path": return widget.path?.isEmpty == false
        case "jobId": return widget.jobId?.isEmpty == false
        case "cells": return widget.cells?.isEmpty == false
        default: return false
        }
    }

    /// Textual containment check mirroring the renderers': collapse `.`
    /// and `..` without touching the filesystem (the path may live on a
    /// remote host) and reject anything that leaves the root or starts
    /// at one.
    static func escapesProjectRoot(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("~") { return true }
        var depth = 0
        for component in path.split(separator: "/") {
            switch component {
            case ".", "": continue
            case "..":
                depth -= 1
                if depth < 0 { return true }
            default: depth += 1
            }
        }
        return false
    }
}
