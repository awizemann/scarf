import AppKit
import Foundation
import ScarfCore
import os

/// Quits the running app and brings up a fresh instance of the same
/// bundle. Used by the Profile-switching flow (issue #70) so the new
/// active profile lands in a process that has never observed the old
/// one — sidesteps any in-process cache or service-state bug that
/// might still be reading from the previous profile's home directory.
///
/// The pairing is intentional:
/// 1. Caller invokes `try AppRelauncher.relaunch()`. That spawns a
///    fresh `open -n <bundleURL>`, captures stderr/exitCode, returns
///    success once the launcher has acknowledged the dispatch.
/// 2. Caller schedules `NSApp.terminate(nil)` 250ms later. The
///    250ms gives macOS time to begin launching the second PID so
///    the dock-icon hand-off looks smooth (no flash of missing
///    icon). Without the gap, macOS can briefly show zero Scarf
///    icons in the dock.
///
/// Refuses to relaunch when the running bundle is under
/// `DerivedData/` or `Build/Products/Debug` — that's an Xcode
/// debug session, and `terminate(nil)` would kill the run mid-debug
/// without giving the new instance any way to attach. The caller
/// surfaces a "restart manually" toast in that case.
@MainActor
enum AppRelauncher {

    /// C10 budget for the `open(1)` dispatch. There is no `-W`, so this is a
    /// LaunchServices hand-off that returns immediately in every healthy
    /// case; 20s is "the world is broken", not "the app is slow to start".
    nonisolated static let openTimeout: TimeInterval = 20
    nonisolated static let logger = Logger(subsystem: "com.scarf.app", category: "AppRelauncher")

    enum RelaunchError: Error, LocalizedError {
        case debugBuild
        case openFailed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .debugBuild:
                return "Refusing to relaunch from an Xcode debug build."
            case .openFailed(let code, let stderr):
                return "open(1) exited \(code): \(stderr)"
            }
        }
    }

    /// Spawns a fresh instance of the running app via `/usr/bin/open -n
    /// <bundleURL>` and returns once the launcher process has dispatched
    /// the new instance. The caller is responsible for the subsequent
    /// `NSApp.terminate(nil)` (deferred ~250ms for a smooth dock hand-off).
    /// Throws `.debugBuild` when launched from Xcode/DerivedData;
    /// `.openFailed` when `open` itself errored.
    ///
    /// **`nonisolated`, and it must stay that way** (t-b15ba4c3). Round-3 P33
    /// bounded this wait at 20 s, which is the C10 timeout half — but the
    /// wait still ran ON the main actor, so a wedged `lsd`/`launchservicesd`
    /// froze the window for the whole 20 s with no way out. The body touches
    /// only `Bundle.main`, `Process` and the logger, none of which need the
    /// main actor; the caller hops back for `NSApp.terminate`.
    /// `async` since round-5 P48 (t-12d04477): the reap is
    /// `waitDrainingAsync`, so the 20 s budget parks a DEDICATED thread
    /// rather than one of the cooperative pool's. The caller's
    /// `Task.detached` never moved the block — `Task.detached` IS that pool.
    nonisolated static func relaunch() async throws {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path
        if path.contains("/DerivedData/")
            || path.contains("/Build/Products/Debug")
            || path.contains("/Build/Products/Debug-")
        {
            logger.warning("Refusing relaunch — running from Xcode build (\(path, privacy: .public))")
            throw RelaunchError.debugBuild
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n: force a NEW instance (without it, `open` activates the
        // running app and we'd never get a fresh process).
        // Pass the bundle URL directly (not -a <bundleId>) so signed
        // dev clones in `~/Applications` still resolve correctly.
        // No -W: we want `open` to return immediately after dispatch,
        // not block until the spawned app exits.
        proc.arguments = ["-n", path]

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = stdoutPipe

        do {
            try proc.run()
        } catch {
            // Never launched, so no reader owns the read ends: all four are
            // ours to close.
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForWriting.close()
            throw RelaunchError.openFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        // C10: bounded, and drained CONCURRENTLY with the wait. `open(1)`
        // is normally instant, but it talks to LaunchServices — which can
        // block on a wedged `lsd`/`launchservicesd`, and an unbounded wait
        // here freezes the relaunch gesture with no way out.
        let (exited, drained) = await proc.waitDrainingAsync(
            timeout: Self.openTimeout, pipes: [stderrPipe, stdoutPipe])
        let errData = drained.first ?? Data()
        // `waitDraining` closes the READ ends (each reader closes the handle
        // it drained) — those are the ones that really leak: 50 spawns holding
        // their `Pipe`s and never closing the read ends took /dev/fd from 4 to
        // 104, exactly 2 per spawn. The WRITE ends do NOT leak after a
        // successful `run()`: Foundation closes the parent's copy as part of
        // the spawn, and the same 50-spawn count stayed flat at 4 whether or
        // not these two lines ran (measured, round-4 P43b — the earlier
        // "every relaunch leaked two fds" rationale here was wrong).
        //
        // They are kept because they are not always no-ops: on the
        // launch-failure path above `run()` never spawned, so the parent's
        // write ends are still open and these are the real release. Closing an
        // already-closed handle is a harmless `EBADF` the `try?` eats, and one
        // unconditional release is easier to keep right than two paths that
        // must agree on who spawned.
        try? stderrPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForWriting.close()

        guard exited else {
            logger.warning("open(1) did not finish within \(Int(Self.openTimeout))s")
            throw RelaunchError.openFailed(
                exitCode: -1,
                stderr: "open(1) did not finish within \(Int(Self.openTimeout))s and was stopped")
        }
        guard proc.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.warning("open(1) failed (\(proc.terminationStatus)): \(stderr, privacy: .public)")
            throw RelaunchError.openFailed(exitCode: proc.terminationStatus, stderr: stderr)
        }

        logger.info("Relaunch dispatched for \(path, privacy: .public)")
    }
}
