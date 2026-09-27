import Foundation

/// Which cron jobs belong to which project — the one rule every project
/// surface applies (the project record, archive/restore, the AGENTS.md
/// block's cron list, the cockpit's cron panel).
///
/// Hermes has no notion of a project on a cron job: it stores `--name`
/// verbatim (`cron/jobs.py:498` @ v2026.9.24), so Scarf attributes by a tag
/// at the start of the name:
///
/// - `[proj:<uuid>] …` — a job created for one project (fleet-apply, the
///   agent following the AGENTS.md block).
/// - `[tmpl:<templateId>] [proj:<uuid>] …` — a job a template install
///   created. The project tag was added because the template tag alone is
///   shared by every project installed from the same template, so each of
///   them claimed (and archiving each of them paused) all of those jobs.
/// - `[tmpl:<templateId>] …` with no project tag — a template job created by
///   an older Scarf. Still attributed by template id alone, because nothing
///   on the job says which install made it.
public enum ProjectCronAttribution {

    public static func projectTag(_ projectID: UUID) -> String {
        "[proj:\(projectID.uuidString)]"
    }

    public static func templateTag(_ templateId: String) -> String {
        "[tmpl:\(templateId)]"
    }

    /// The name a template install gives a job whose planned name is
    /// `[tmpl:<id>] <name>`: the project tag goes right after the template
    /// tag. A name without the template tag (never produced by the planner)
    /// is returned unchanged.
    public static func templateJobName(
        _ plannedName: String, templateId: String, projectID: UUID
    ) -> String {
        let tmpl = templateTag(templateId)
        guard plannedName.hasPrefix(tmpl) else { return plannedName }
        let rest = plannedName.dropFirst(tmpl.count).drop(while: { $0 == " " })
        return tmpl + " " + projectTag(projectID) + " " + rest
    }

    /// Does the job named `jobName` carry this project's own tag, either
    /// first or right after a template tag? Unlike ``isAttributed(jobName:projectID:templateId:)``
    /// it never matches on a template tag alone, which every project
    /// installed from that template shares.
    public static func namesProject(jobName: String, projectID: UUID) -> Bool {
        let proj = projectTag(projectID)
        if jobName.hasPrefix(proj) { return true }
        guard jobName.hasPrefix("[tmpl:"), let close = jobName.firstIndex(of: "]") else { return false }
        return jobName[jobName.index(after: close)...].drop(while: { $0 == " " }).hasPrefix(proj)
    }

    /// Does the job named `jobName` belong to the project with this id and
    /// (when it was installed from a template) this template id?
    public static func isAttributed(
        jobName: String, projectID: UUID, templateId: String?
    ) -> Bool {
        let proj = projectTag(projectID)
        if jobName.hasPrefix(proj) { return true }
        guard let templateId else { return false }
        let tmpl = templateTag(templateId)
        guard jobName.hasPrefix(tmpl) else { return false }
        let rest = jobName.dropFirst(tmpl.count).drop(while: { $0 == " " })
        // A template job that names its project belongs to that one only.
        if rest.hasPrefix("[proj:") { return rest.hasPrefix(proj) }
        return true
    }
}
