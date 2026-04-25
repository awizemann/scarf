import Foundation
#if canImport(os)
import os
#endif

/// Runs lightweight host-side `which <bin>` probes for skills that
/// declare runtime dependencies. Used by the Skills view (Mac + iOS)
/// to surface a yellow banner when a prereq is missing on the Hermes
/// host — e.g. the `design-md` skill needs `npx` (Node.js 18+).
///
/// Pure transport-driven probes; never blocks the UI thread (callers
/// invoke from async context). No state — call once per skill view per
/// appear and cache in the calling view-model.
public struct SkillPrereqService: Sendable {
    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.scarf",
        category: "SkillPrereqService"
    )
    #endif

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Result of a single prereq probe. Surfaced verbatim by the UI:
    /// `present` → no banner; `missing` → yellow banner with `installHint`.
    public enum Status: Sendable, Equatable {
        case present
        case missing(installHint: String)
        case unknown(reason: String)
    }

    /// Check whether `binary` resolves on the host's PATH. Returns
    /// `.present` on exit code 0, `.missing(installHint:)` on a clean
    /// not-found exit, `.unknown(reason:)` on any transport error.
    /// `installHint` is the `installHints` table entry below if known;
    /// callers can override for skills with bespoke install steps.
    public nonisolated func probe(
        binary: String,
        installHint: String? = nil
    ) async -> Status {
        let ctx = context
        let resolvedHint = installHint ?? Self.installHints[binary] ?? "Install `\(binary)` on the Hermes host."
        return await Task.detached {
            let transport = ctx.makeTransport()
            do {
                let result = try transport.runProcess(
                    executable: "/usr/bin/env",
                    args: ["which", binary],
                    stdin: nil,
                    timeout: 4
                )
                if result.exitCode == 0,
                   !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .present
                }
                return .missing(installHint: resolvedHint)
            } catch {
                #if canImport(os)
                Self.logger.warning(
                    "prereq probe for \(binary, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                #endif
                return .unknown(reason: error.localizedDescription)
            }
        }.value
    }

    /// Built-in install hints for the binaries we know about. Skills
    /// can pass a custom hint via `probe(binary:installHint:)` if they
    /// want bespoke language. Keep these short — the banner has limited
    /// vertical real estate on iPhone.
    public static let installHints: [String: String] = [
        "npx": "Install Node.js 18+ on the Hermes host (`brew install node` on macOS, `apt install nodejs npm` on Debian/Ubuntu).",
        "node": "Install Node.js 18+ on the Hermes host.",
        "gws": "Install the `gws` CLI on the Hermes host (Google Workspace skill).",
        "ffmpeg": "Install `ffmpeg` on the Hermes host (`brew install ffmpeg` / `apt install ffmpeg`).",
    ]
}
