import AppKit
import Foundation
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
    static let openTimeout: TimeInterval = 20
    static let logger = Logger(subsystem: "com.scarf.app", category: "AppRelauncher")

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
    static func relaunch() throws {
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
            throw RelaunchError.openFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        // C10: bounded, and drained CONCURRENTLY with the wait. `open(1)`
        // is normally instant, but it talks to LaunchServices — which can
        // block on a wedged `lsd`/`launchservicesd`, and an unbounded wait
        // here freezes the relaunch gesture with no way out.
        let (exited, drained) = proc.waitDraining(
            timeout: Self.openTimeout, pipes: [stderrPipe, stdoutPipe])
        let errData = drained.first ?? Data()

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
