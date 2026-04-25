import Foundation
#if canImport(os)
import os
#endif

/// Resolves the current git branch of a project directory via the
/// transport (so it works against local + remote SSH projects without
/// any platform-specific branching). The result is informational —
/// surfaced in the chat header alongside the project name as a small
/// `branch` chip. No write operations.
///
/// Per-session caching lives on the chat view models (one read per chat
/// session start); this service is stateless.
///
/// **Failure model.** Returns `nil` when the directory isn't a git
/// repo, when `git` is missing on the host, or when the SSH connection
/// drops. Never throws — the chat header simply omits the branch chip
/// on any error.
public struct GitBranchService: Sendable {
    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.scarf",
        category: "GitBranchService"
    )
    #endif

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Resolve the current branch name at `projectPath`. Returns nil
    /// for non-git directories, missing `git`, or transport errors —
    /// callers treat nil as "no branch chip to render."
    ///
    /// Internally runs `git -C <path> rev-parse --abbrev-ref HEAD`.
    /// On a clean checkout that's a branch name like "main"; on a
    /// detached HEAD it's literally "HEAD" (which we then return as
    /// nil, since "HEAD" isn't a useful branch label).
    public nonisolated func branch(at projectPath: String) async -> String? {
        let ctx = context
        return await Task.detached {
            let transport = ctx.makeTransport()
            do {
                let result = try transport.runProcess(
                    executable: "git",
                    args: ["-C", projectPath, "rev-parse", "--abbrev-ref", "HEAD"],
                    stdin: nil,
                    timeout: 5
                )
                guard result.exitCode == 0 else {
                    return nil
                }
                let raw = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty || raw == "HEAD" { return nil }
                return raw
            } catch {
                #if canImport(os)
                Self.logger.warning(
                    "git branch lookup failed at \(projectPath, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                #endif
                return nil
            }
        }.value
    }
}
