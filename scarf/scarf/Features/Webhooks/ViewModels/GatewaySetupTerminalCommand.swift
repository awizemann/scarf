import Foundation
import ScarfCore

/// The Terminal.app command line that runs `hermes gateway setup` against
/// the WINDOW's host and profile.
///
/// The Webhooks tab's button used to run the LOCAL `hermes` with no profile
/// pin, so a remote window configured this Mac, and a named-profile window
/// configured whatever `active_profile` pointed at. A remote window now goes
/// through `ssh -t`, built the same way `ChatViewModel.launchTerminal` builds
/// its remote argv: `env` + the PATH fallback (a non-login shell), the
/// `HERMES_HOME=` pin for a named profile or `-p default` for the root.
///
/// Every argv word is single-quoted for the LOCAL shell Terminal runs, so the
/// remote words (`PATH="$PATH"":…"`, the already remote-quoted `HERMES_HOME=`,
/// the binary as `HermesPathSet.hermesBinaryShellWord`) reach ssh unexpanded
/// and the remote login shell — which may be csh/tcsh — parses them as the
/// chat path's argv does.
enum GatewaySetupTerminalCommand {

    static func argv(for context: ServerContext) -> [String] {
        argv(for: context, hermesArgs: ["gateway", "setup"])
    }

    /// The same shape for any interactive `hermes` verb. `localForwards` are
    /// `ssh -L` specs (`<local port>:<host>:<remote port>`), used only for a
    /// remote window — S07-F6's Spotify sign-in forwards Hermes's loopback
    /// OAuth callback port so the Mac's browser can reach it.
    static func argv(for context: ServerContext, hermesArgs: [String], localForwards: [String] = []) -> [String] {
        let home = context.paths.home
        let hermes = context.paths.hermesBinary
        if case .ssh(let cfg) = context.kind,
           let remote = context.remoteLoginShellHermesWords(args: hermesArgs) {
            let host = cfg.user.map { "\($0)@\(cfg.host)" } ?? cfg.host
            var args: [String] = ["/usr/bin/ssh", "-t"]
            if let port = cfg.port { args += ["-p", String(port)] }
            if let id = cfg.identityFile, !id.isEmpty { args += ["-i", id] }
            for forward in localForwards { args += ["-L", forward] }
            args += ["-o", "StrictHostKeyChecking=accept-new", host, "--"] + remote
            return args
        }
        // Local: the same pin, but the assignment is for THIS shell, so it
        // goes in as `env HERMES_HOME=<home>` with the path unquoted by us
        // (the argv word is quoted as a whole below).
        var args: [String] = []
        if HermesProfileScope.isProfileHome(home) { args += ["/usr/bin/env", "HERMES_HOME=" + home] }
        args.append(hermes)
        args += HermesProfileScope.pinnedRemoteArguments(
            executable: hermes, args: hermesArgs, home: home)
        return args
    }

    /// `argv` as one line for the local shell.
    static func shellLine(for context: ServerContext) -> String {
        shellLine(for: context, hermesArgs: ["gateway", "setup"])
    }

    static func shellLine(for context: ServerContext, hermesArgs: [String], localForwards: [String] = []) -> String {
        argv(for: context, hermesArgs: hermesArgs, localForwards: localForwards)
            .map(singleQuote).joined(separator: " ")
    }

    /// An AppleScript that opens Terminal and runs `shellLine`.
    static func appleScript(for context: ServerContext) -> String {
        appleScript(forShellLine: shellLine(for: context))
    }

    static func appleScript(forShellLine shellLine: String) -> String {
        let line = shellLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\n  activate\n  do script \"\(line)\"\nend tell"
    }

    nonisolated static func singleQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
