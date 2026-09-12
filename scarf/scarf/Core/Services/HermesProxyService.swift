import Foundation
import ScarfCore
import os

/// Manages the `hermes proxy start` subprocess lifecycle for Scarf's
/// Hermes Proxy panel. Owns one optional long-running `Process` per
/// instance plus a recent-log buffer drained from the child's stderr
/// (Hermes writes the startup banner + ongoing chatter to stderr;
/// stdout is reserved for proxied request bodies).
///
/// **Local-only in v1.** The proxy is most useful as a local OpenAI-
/// compatible endpoint for tools running on the same machine (Codex,
/// Aider, Cline, VS Code Continue). SSH-deployed remote hosts would
/// require an additional port-forward step on top of starting the
/// child; that's a follow-up. Scarf's Proxy sidebar entry is hidden
/// for non-`.local` contexts so the user doesn't get a broken Start
/// button on SSH'd servers.
///
/// Hermes wire shape (v0.14):
///   `hermes proxy start --provider nous --host 127.0.0.1 --port 8645`
/// Default port is 8645. Adapter registry in v0.14 ships with only
/// `nous`; future Hermes versions will register more adapters and
/// `hermes proxy providers` will list them.
@MainActor
@Observable
final class HermesProxyService {
    /// Default port from `hermes_cli/proxy/server.py` (`DEFAULT_PORT`).
    /// Kept here in sync with Hermes; bump if upstream changes.
    nonisolated static let defaultPort: Int = 8645
    /// Default host from `hermes_cli/proxy/server.py` (`DEFAULT_HOST`).
    nonisolated static let defaultHost: String = "127.0.0.1"

    private let logger = Logger(subsystem: "com.scarf", category: "HermesProxyService")
    private let context: ServerContext

    /// The currently-running `hermes proxy` child process, or nil when
    /// the proxy is stopped. Owned exclusively by this service — the
    /// view model reads `isRunning` instead of touching the Process.
    private var child: Process?

    /// Tracks startup-time stderr output for the panel's log tail. Cap
    /// is generous enough to fit the boot banner + a few lines of
    /// drift but small enough that a misbehaving proxy can't drive
    /// memory growth.
    private(set) var logLines: [String] = []
    private static let logCap: Int = 200

    /// True when a child Process is alive. Driven by `start()` /
    /// `stop()` and by `processDidExit()` — keep this honest because
    /// the UI start/stop buttons read it directly.
    private(set) var isRunning: Bool = false

    /// Last-known endpoint URL. nil when the proxy is stopped.
    private(set) var endpoint: URL?

    /// Provider currently routed by the running proxy. nil when stopped.
    private(set) var routedProvider: String?

    /// Last error surfaced during launch (e.g. "port already in use").
    /// Cleared on the next successful start.
    private(set) var lastError: String?

    init(context: ServerContext) {
        self.context = context
    }

    /// Spawn `hermes proxy start --provider <p> --host <h> --port <n>`
    /// in the background. The child inherits the PATH-enriched env
    /// from `HermesFileService.enrichedEnvironment()` so it can find
    /// node / npx / system tools even when Scarf was launched via
    /// Finder (no login shell).
    func start(provider: String, host: String = defaultHost, port: Int = defaultPort) {
        guard !isRunning else { return }
        guard context.id == ServerContext.local.id else {
            lastError = "Hermes Proxy can only be launched against the local server in this release."
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: context.paths.hermesBinary)
        proc.arguments = ["proxy", "start", "--provider", provider, "--host", host, "--port", String(port)]
        proc.environment = HermesFileService.enrichedEnvironment()

        let pipe = Pipe()
        proc.standardError = pipe
        // Discard: proxied bodies on stdout aren't surfaced. `FileHandle.nullDevice`,
        // never a `Pipe()` — a pipe nobody reads is not a discard, it is a 64 KB
        // buffer that the proxy blocks in `write()` on as soon as it fills, and
        // this child is meant to run for hours. `/dev/null` swallows any volume
        // and costs no fd of ours to close (C10, round-4 P43).
        proc.standardOutput = FileHandle.nullDevice

        // Hook readability so log lines arrive without polling. The
        // closure captures `[weak self]` and hops to MainActor for
        // the mutation — the readable handler fires on a dispatch
        // queue, not the main actor.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            Task { @MainActor [weak self] in
                self?.appendLog(lines: lines)
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            // Drain the read pipe before nilling the handler so the
            // last buffered bytes don't get dropped. Then the
            // MainActor hop flips state.
            if let pipe = terminated.standardError as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
                if let trailing = try? pipe.fileHandleForReading.readToEnd(),
                   let text = String(data: trailing, encoding: .utf8),
                   !text.isEmpty {
                    Task { @MainActor [weak self] in
                        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        self?.appendLog(lines: lines)
                    }
                }
            }
            Task { @MainActor [weak self] in
                self?.processDidExit(status: terminated.terminationStatus)
            }
        }

        do {
            try proc.run()
            child = proc
            isRunning = true
            routedProvider = provider
            endpoint = URL(string: "http://\(host):\(port)/v1")
            lastError = nil
            logger.info("hermes proxy started on \(host, privacy: .public):\(port, privacy: .public) with provider \(provider, privacy: .public)")
        } catch {
            lastError = "Could not launch hermes proxy: \(error.localizedDescription)"
            logger.error("hermes proxy launch failed: \(error.localizedDescription, privacy: .public)")
            // Tear down the half-initialized pipe. `run()` threw, so nothing
            // spawned; `Pipe.deinit` would close both ends on its own
            // (measured — the audit's "leaks 2 fds" reading of this arm does
            // not hold), so these are the explicit release at a point the
            // code states, and the handler must be detached either way
            // (round-5 P48).
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    /// Ask the child to stop, insisting if it does not. Idempotent.
    ///
    /// SIGTERM alone was the whole of this: no escalation and no ceiling, so
    /// a `hermes proxy` that installs SIGTERM to ignore, or that is wedged in
    /// an uninterruptible wait, left the Stop button looking like it had
    /// worked while the child ran on — holding port 8645 against the next
    /// Start (round-5 P48). `waitUntilExit(timeout:)` is SIGTERM → bounded
    /// poll → pid-guarded SIGKILL → bounded poll and returns either way.
    ///
    /// The escalation runs OFF the main actor: it can block for up to
    /// `Self.stopCeiling` plus the primitive's own two signal graces, and
    /// this service is `@MainActor` (C10 — never block the main actor on a
    /// process). The `terminationHandler` still flips `isRunning` and clears
    /// state on its own MainActor hop, so nothing here needs to.
    ///
    /// **SIGTERM goes first, here, before the wait.** `waitUntilExit(timeout:)`
    /// signals only once its budget is SPENT, so handing it `stopCeiling` and
    /// nothing else polled a child nobody had asked to leave for three full
    /// seconds — strictly worse than the bare `terminate()` this replaced, and
    /// the opposite of what `stopCeiling` is documented to be. The ask is
    /// free and immediate; the ceiling is the grace AFTER it, which is why
    /// every other escalation in the app passes `timeout: 0` to a child it has
    /// already signalled or already given its budget (`StreamingChild.reap`,
    /// `SSHTransport.runLocal`, `TestConnectionProbe`) — round-5 P48b.
    func stop() {
        guard let proc = child, proc.isRunning else { return }
        let ceiling = Self.stopCeiling
        proc.terminate()
        // A THREAD, not `Task.detached`: the primitive is a `Thread.sleep`
        // poll loop, and `Task.detached` runs on the same cooperative pool
        // the caller is on — one thread per core, unable to grow. Same
        // reasoning as `Process.waitDrainingAsync` (round-4 P43c).
        Thread.detachNewThread {
            _ = proc.waitUntilExit(timeout: ceiling)
        }
    }

    /// How long to let `hermes proxy` shut down cleanly before SIGKILL.
    /// Short: the proxy has no work to flush — the panel's log tail is the
    /// only thing reading it, and a clean exit is immediate.
    nonisolated static let stopCeiling: TimeInterval = 3

    /// Clear the log buffer. Useful when the user wants to start
    /// fresh after a failed launch.
    func clearLog() {
        logLines.removeAll()
    }

    private func appendLog(lines: [String]) {
        for line in lines where !line.isEmpty {
            logLines.append(line)
        }
        if logLines.count > Self.logCap {
            logLines.removeFirst(logLines.count - Self.logCap)
        }
    }

    private func processDidExit(status: Int32) {
        child = nil
        isRunning = false
        endpoint = nil
        routedProvider = nil
        if status != 0 && lastError == nil {
            lastError = "hermes proxy exited with status \(status). See log."
        }
        logger.info("hermes proxy stopped (exit \(status))")
    }

    /// Probe `hermes proxy providers` for the list of available
    /// upstream adapters. Returns adapter IDs (e.g. `["nous"]` in
    /// v0.14). Falls back to a hardcoded `["nous"]` if the probe
    /// fails so the picker still shows something usable. Off
    /// MainActor — uses `runHermesCLI` synchronously inside a
    /// detached task.
    nonisolated func listAvailableProviders() async -> [String] {
        await Task.detached(priority: .utility) { [context] in
            let svc = HermesFileService(context: context)
            let result = svc.runHermesCLI(args: ["proxy", "providers"], timeout: 10)
            guard result.exitCode == 0 else { return ["nous"] }
            // Output format from `cmd_proxy_list_providers`:
            //   Available proxy upstream providers:
            //     nous  — Nous Portal
            // Parse defensively — strip the header + extract the
            // first whitespace-delimited token from each subsequent
            // line.
            var ids: [String] = []
            for line in result.output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasSuffix(":") { continue }
                if let id = trimmed.split(separator: " ", maxSplits: 1).first {
                    ids.append(String(id))
                }
            }
            return ids.isEmpty ? ["nous"] : ids
        }.value
    }
}
