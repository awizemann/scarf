import Foundation
import ScarfCore
#if canImport(AppKit)
import AppKit
#endif

/// `ServerContext` extensions that depend on main-target services
/// (`HermesFileService`) or macOS-only frameworks (`AppKit.NSWorkspace`).
///
/// These stay in the Mac app target so `ScarfCore` itself has no dependency
/// on AppKit or on the Mac app's services. The iOS target will provide its
/// own equivalents (or skip these features entirely) via its own
/// `ServerContext+iOS.swift` when it lands in M2+.
extension ServerContext {
    /// Invoke the `hermes` CLI on this server and return its combined output
    /// + exit code. Local: spawns the local binary via `Process`. Remote:
    /// rounds through `ssh host hermes …`. Use this from any VM that needs
    /// to fire off a CLI command — never spawn `hermes` via `Process()`
    /// directly, because that path bypasses the transport for remote.
    @discardableResult
    nonisolated func runHermes(_ args: [String], timeout: TimeInterval = 60, stdin: String? = nil) -> (output: String, exitCode: Int32) {
        let result = HermesFileService(context: self).runHermesCLI(args: args, timeout: timeout, stdinInput: stdin)
        return (result.output, result.exitCode)
    }

    /// Reveal the file at `path` in the user's local editor (via
    /// `NSWorkspace.open`). For remote contexts this is a no-op — the
    /// file doesn't exist on this Mac, so opening it would fail silently
    /// or worse, open the wrong file from the local filesystem.
    /// Returns `true` if opened, `false` if the call was skipped.
    @discardableResult
    func openInLocalEditor(_ path: String) -> Bool {
        guard !isRemote else { return false }
        #if canImport(AppKit)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
        #else
        return false
        #endif
    }
}
