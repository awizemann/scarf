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
            // A remote shell finds `git` on its PATH. Locally the transport
            // launches the executable path as given, so a bare "git" became
            // `/git` and the Mac never showed the chip (S11-F3).
            let git: String
            if ctx.isRemote {
                git = "git"
            } else {
                #if os(macOS)
                let path = LocalTransport.subprocessEnvironment(forExecutable: "git")["PATH"]
                guard let found = Self.localGitExecutable(searchPath: path) else { return nil }
                git = found
                #else
                return nil
                #endif
            }
            do {
                let result = try transport.runProcess(
                    executable: git,
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

    /// The local `git` to run: the first one on `searchPath` (the login
    /// shell's PATH), then the Homebrew and system locations.
    ///
    /// `/usr/bin/git` is only a stub until Apple's developer tools are
    /// installed, and running it without them pops the "install command
    /// line developer tools" dialog. The chip is looked up for every project
    /// chat, git repo or not, so the stub is skipped unless the tools are
    /// there; without any git the chip is simply hidden.
    nonisolated static func localGitExecutable(
        searchPath: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        developerToolsInstalled: () -> Bool = GitBranchService.developerToolsInstalled
    ) -> String? {
        let dirs = (searchPath ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("git")
            guard isExecutable(candidate) else { continue }
            if candidate == "/usr/bin/git", !developerToolsInstalled() { continue }
            return candidate
        }
        return nil
    }

    /// True when `/usr/bin/git` has real tools behind it: a developer
    /// directory chosen with `xcode-select`, the Command Line Tools, or
    /// Xcode in its default place.
    nonisolated static func developerToolsInstalled() -> Bool {
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty,
           fm.fileExists(atPath: dir) { return true }
        if let link = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"),
           fm.fileExists(atPath: link) { return true }
        return fm.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer")
    }
}
