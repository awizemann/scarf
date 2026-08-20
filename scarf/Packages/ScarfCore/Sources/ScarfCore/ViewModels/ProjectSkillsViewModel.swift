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
            let exitCode: Int32
            do {
                exitCode = try xport.runProcess(
                    executable: bin,
                    args: args,
                    stdin: nil,
                    timeout: 60
                ).exitCode
            } catch {
                exitCode = -1
            }
            await self?.finishTrust(trusted: trusted, exitCode: exitCode)
        }
    }

    private func finishTrust(trusted: Bool, exitCode: Int32) async {
        isBusy = false
        if exitCode == 0 {
            message = trusted
                ? "Trusted — this repo's skills will load in sessions started here."
                : "Untrusted — this repo's skills will no longer load."
        } else {
            message = trusted ? "Trust failed" : "Untrust failed"
        }
        await load()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        message = nil
    }
}
