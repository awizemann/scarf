import Foundation

/// Drives the per-project Skills panel: what repo-local skills a
/// checkout carries, whether Hermes trusts the checkout, and the
/// trust/untrust actions.
///
/// Hermes v0.20.4+ only. Call sites gate on
/// `HermesCapabilities.hasSkillsProjectTrust` — on older hosts the CLI
/// has no `skills trust` verb and the config key is meaningless, so the
/// panel isn't offered at all.
@Observable
@MainActor
public final class ProjectSkillsViewModel {
    private let context: ServerContext
    private let transport: any ServerTransport

    public let projectRoot: String

    public private(set) var skills: [ProjectSkill] = []
    public private(set) var isTrusted = false
    public private(set) var isLoading = false
    public private(set) var isBusy = false
    public private(set) var message: String?

    public init(context: ServerContext, projectRoot: String) {
        self.context = context
        self.transport = context.makeTransport()
        self.projectRoot = ProjectSkillsScanner.normalizedRoot(projectRoot)
    }

    /// True when the repo has skills on disk that Hermes is ignoring.
    public var hasUntrustedSkills: Bool { !isTrusted && !skills.isEmpty }

    public func load() async {
        isLoading = true
        let ctx = context
        let xport = transport
        let root = projectRoot
        let snapshot = await Task.detached {
            ProjectSkillsScanner.scan(projectRoot: root, context: ctx, transport: xport)
        }.value
        skills = snapshot.skills
        isTrusted = snapshot.isTrusted
        isLoading = false
    }

    public func setTrusted(_ trusted: Bool) {
        guard !isBusy else { return }
        isBusy = true
        let bin = context.paths.hermesBinary
        let xport = transport
        let args = ProjectSkillsScanner.trustArgs(projectRoot, trusted: trusted)
        Task.detached { [weak self] in
            let outcome: HermesCLIOutcome
            do {
                let result = try xport.runProcess(
                    executable: bin,
                    args: args,
                    stdin: nil,
                    timeout: 60
                )
                // P39: judged by OUTPUT, not the exit code. `_cmd_skills_trust`
                // edits `skills.trusted_project_dirs` and hands it to
                // `save_config` (`hermes_cli/main_agent_cmds.py:224`, `:234` @
                // v2026.9.7), whose managed-install arm prints to stderr and
                // `return`s (`hermes_cli/config.py:2316-2318`) — and the
                // handler then prints `Trusted: <root>` anyway (`:235`). Exit
                // 0, nothing written, and Scarf used to banner the success.
                // Two of its OWN refusals (`Not a directory:` `:197`, `Not
                // inside a git checkout.` `:202-204`) are bare `return`s at
                // exit 0 too. See ``HermesSkillsTrust``.
                outcome = HermesSkillsTrust.judge(
                    output: [result.stdoutString, result.stderrString]
                        .filter { !$0.isEmpty }.joined(separator: "\n"),
                    exitCode: result.exitCode
                )
            } catch {
                outcome = HermesCLIOutcome(succeeded: false, detail: nil)
            }
            await self?.finishTrust(trusted: trusted, outcome: outcome)
        }
    }

    private func finishTrust(trusted: Bool, outcome: HermesCLIOutcome) async {
        isBusy = false
        if outcome.succeeded {
            message = trusted
                ? "Trusted — this repo's skills will load in sessions started here."
                : "Untrusted — this repo's skills will no longer load."
        } else {
            let base = trusted ? "Trust failed" : "Untrust failed"
            message = outcome.detail.map { "\(base): \($0)" } ?? base
        }
        await load()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        message = nil
    }
}
