import Foundation

/// Flags a project's cron job whose prompt creates Kanban tasks without
/// naming the project's tenant (#142 P6).
///
/// Why it matters now: a job with a `workdir` in the project used to load
/// the managed AGENTS.md block, which told the agent to pass
/// `--tenant <tenant>`. On Hermes v0.16+ Scarf strips that block and hands
/// the tenant to CHAT sessions through `HERMES_ENVIRONMENT_HINT` — which a
/// scheduled run never receives — and Hermes has no tenant default, so the
/// job's tasks land under "Untagged". Scarf does not rewrite the job; the
/// cockpit shows a warning with a corrected prompt to copy.
///
/// **The heuristic, deliberately simple.** A prompt needs fixing when BOTH:
/// - it mentions Kanban task creation: `kanban create` (any whitespace
///   between the words, so `hermes kanban create` too) or the
///   `kanban_create` tool name, case-insensitive; and
/// - it names no tenant: neither `--tenant` nor the tenant value itself
///   appears (case-insensitive). The value check keeps a prompt that
///   passes the tenant to the `kanban_create` tool in prose
///   ("tenant scarf:demo") from being flagged.
/// Prose like "file a task on the board" is not caught; a prompt that
/// passes some OTHER tenant with `--tenant` is not flagged. Both are fine:
/// this is a nudge, not a validator.
public enum ProjectCronTenantCheck {

    /// Whether `prompt` creates Kanban tasks without naming `tenant`.
    public static func needsTenant(prompt: String, tenant: String) -> Bool {
        let tenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenant.isEmpty, mentionsKanbanCreate(prompt) else { return false }
        let lower = prompt.lowercased()
        return !lower.contains("--tenant") && !lower.contains(tenant.lowercased())
    }

    /// `prompt` with the tenant spelled out: ` --tenant <tenant>` inserted
    /// after every `kanban create`, and — when there was none to extend
    /// (the prompt only names the `kanban_create` tool) — an instruction
    /// line appended instead. Callers show it for the user to copy; Scarf
    /// never writes it back to the job.
    public static func suggestedPrompt(prompt: String, tenant: String) -> String {
        let tenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        let flag = " --tenant " + tenant
        let matches = cliRegex.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
        if !matches.isEmpty {
            var out = prompt
            for match in matches.reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                out.insert(contentsOf: flag, at: range.upperBound)
            }
            return out
        }
        let separator = prompt.hasSuffix("\n") || prompt.isEmpty ? "" : "\n\n"
        return prompt + separator + instructionLine(tenant: tenant)
    }

    /// The instruction a user can paste into any prompt that creates tasks.
    public static func instructionLine(tenant: String) -> String {
        "When you create Kanban tasks, always pass --tenant \(tenant) to hermes kanban create (or tenant \"\(tenant)\" to the kanban_create tool) so they land on this project's board."
    }

    static func mentionsKanbanCreate(_ prompt: String) -> Bool {
        let range = NSRange(prompt.startIndex..., in: prompt)
        return cliRegex.firstMatch(in: prompt, range: range) != nil
            || prompt.range(of: "kanban_create", options: .caseInsensitive) != nil
    }

    // `\b` so `mykanban create` is not a hit; `\s+` spans a wrapped line.
    private static let cliRegex = try! NSRegularExpression(
        pattern: #"\bkanban\s+create\b"#, options: [.caseInsensitive])
}
