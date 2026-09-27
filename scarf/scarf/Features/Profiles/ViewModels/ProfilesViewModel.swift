import AppKit
import Foundation
import ScarfCore
import os

struct HermesProfile: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let isActive: Bool
    let path: String
}

@Observable
final class ProfilesViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ProfilesViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    /// How `profile list` and the lifecycle verbs (`runAndReload`) spawn.
    /// Production is `HermesFileService.runHermesCLI`; tests inject a fake
    /// so a verb's outcome handling (v0.21.4's settlement-pending delete) is
    /// provable without a Hermes home (see `HermesCLIRunner`).
    @ObservationIgnored nonisolated let cliRunner: HermesCLIRunner

    init(context: ServerContext = .local, cliRunner: HermesCLIRunner? = nil) {
        self.context = context
        let fileService = HermesFileService(context: context)
        self.fileService = fileService
        self.cliRunner = cliRunner ?? { args, timeout in
            let result = fileService.runHermesCLI(args: args, timeout: timeout)
            return (result.output, result.exitCode)
        }
    }


    var profiles: [HermesProfile] = []
    /// The server's active profile, or `nil` when it couldn't be read
    /// (remote only: the `active_profile` read failed), in which case no
    /// row is badged rather than guessing.
    var activeName: String? = "default"
    var isLoading = false
    var message: String?
    var detailOutput: String = ""

    /// Why the last `profile list` failed, or `nil`. Shown in place of the
    /// "No Profiles" empty state (S13-F6): a successful run always prints at
    /// least the default row (`hermes_cli/profile_cmd.py:103-127`), so an
    /// empty list after a failed spawn means "couldn't ask", not "none".
    var loadError: String?

    func load() {
        isLoading = true
        let context = context
        Task.detached { [cliRunner] in
            let result = await OffPool.run {
                cliRunner(["profile", "list"], 20)
            }
            guard result.exitCode == 0 else {
                // Keep the previous list; say why it didn't refresh.
                await MainActor.run {
                    self.isLoading = false
                    self.loadError = Self.failureMessage(result.output)
                }
                return
            }
            let (parsed, marked) = Self.parseProfileList(result.output)
            // Remote: the server's active profile lives in the root's
            // `active_profile` file (see `resolveActive`). A missing file
            // means "default", as it does to Hermes; a failed read means
            // "unknown".
            let hostActiveFile: HostActiveFile = context.isRemote
                ? await OffPool.run {
                    Self.readHostActiveFile(context: context)
                }
                : .missing
            let (profiles, active) = Self.resolveActive(
                parsed: parsed, markedActive: marked,
                isRemote: context.isRemote, hostActiveFile: hostActiveFile)
            await MainActor.run {
                self.isLoading = false
                self.loadError = nil
                self.profiles = profiles
                self.activeName = active
            }
        }
    }

    func showDetail(_ profile: HermesProfile) {
        detailOutput = "Loading…"
        Task.detached { [fileService] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: ["profile", "show", "--", profile.name], timeout: 15)
            }
            await MainActor.run {
                self.detailOutput = result.output
            }
        }
    }

    /// Set the active profile via `hermes profile use <name>` without
    /// relaunching Scarf. Most users will reach for `switchAndRelaunch`
    /// instead — kept here so the context-menu "Use" item stays
    /// functional and so callers that genuinely want a no-relaunch
    /// switch (tests, scripted setups) have a path. Invalidates the
    /// resolver cache on success so the next `context.paths` access
    /// picks up the new home directory.
    func switchTo(_ profile: HermesProfile) {
        Task.detached { [fileService, self] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: ["profile", "use", "--", profile.name], timeout: 60)
            }
            await MainActor.run {
                if result.exitCode == 0 {
                    HermesProfileResolver.invalidateCache()
                    self.message = String(localized: "Active profile set to \(profile.name) — restart Scarf to refresh.")
                } else {
                    self.message = Self.failureMessage(result.output)
                }
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    /// Set the active profile and immediately relaunch Scarf. The
    /// canonical user-facing switch path (issue #70): a fresh process
    /// guarantees every service constructs from the new
    /// `~/.hermes/active_profile` value, sidestepping any in-process
    /// state that might still be holding the previous profile's
    /// data. Failures fall back to a "restart manually" toast.
    @MainActor
    func switchAndRelaunch(_ profile: HermesProfile) {
        Task.detached { [fileService, self] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: ["profile", "use", "--", profile.name], timeout: 30)
            }
            let switched = await MainActor.run { () -> Bool in
                guard result.exitCode == 0 else {
                    self.message = Self.failureMessage(result.output)
                    self.load()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.message = nil
                    }
                    return false
                }
                HermesProfileResolver.invalidateCache()
                return true
            }
            guard switched else { return }
            // `relaunch()` spawns `open(1)` and waits up to 20 s for it. That
            // wait stays OUT here in the detached task (t-b15ba4c3): it talks
            // to LaunchServices, and a wedged `lsd` used to freeze the window
            // for the full budget. Only the verdict hops back.
            do {
                try await AppRelauncher.relaunch()
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApp.terminate(nil)
                    }
                }
            } catch AppRelauncher.RelaunchError.debugBuild {
                await MainActor.run {
                    self.message = "Profile switched to \(profile.name). Restart Scarf manually (Xcode-launched instance)."
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.message = "Profile switched to \(profile.name). Please quit and reopen Scarf manually."
                    self.load()
                }
            }
        }
    }

    /// P60: the idle twin of `rename` / `delete` below. `profile_name` is a
    /// plain positional (`hermes_cli/subcommands/profile.py:19` @
    /// `v2026.9.7`), so a name beginning with `-` is read as a flag here too
    /// — `--` was added to the two destructive verbs at P47 and this one was
    /// left. The separator goes last, after every option.
    func create(name: String, cloneConfig: Bool, cloneAll: Bool, noSkills: Bool = false) {
        var args = ["profile", "create"]
        if cloneAll { args.append("--clone-all") }
        else if cloneConfig { args.append("--clone") }
        // v0.13+: Empty-profile creation. The wire is independent of
        // --clone / --clone-all per the v0.13 release notes — the user
        // can stack `--clone --no-skills` to clone config but skip
        // skills, which is a plausible workflow. The UI still disables
        // the toggle under --clone-all (Decision H, see ProfilesView)
        // but the wire is permissive.
        if noSkills { args.append("--no-skills") }
        args += ["--", name]
        runAndReload(args, success: String(localized: "Profile '\(name)' created"))
    }

    /// `rename` takes two plain positionals — `old_name` and `new_name`
    /// (`hermes_cli/subcommands/profile.py:77`, `:79` @ `v2026.9.7`) — and
    /// no list-valued option stands behind them, so `--` is safe here by
    /// P47's rule and necessary for the same reason it is on `show`/`use`:
    /// a profile whose name begins with `-` is otherwise parsed as a flag.
    func rename(_ profile: HermesProfile, to newName: String) {
        runAndReload(["profile", "rename", "--", profile.name, newName], success: String(localized: "Renamed"))
    }

    /// Deletes a profile.
    ///
    /// `-y` is required, not optional: without it `profile delete` blocks
    /// on its own stdin confirmation, and on Scarf's non-tty pipe the read
    /// hits EOF, the CLI takes the safe default (don't delete), and exits
    /// **0** — so Scarf reported "Deleted <name>" for a profile that is
    /// still there. The flag has been on the `profile delete` parser since
    /// at least v0.12.0 (verified present at v2026.4.30 and every tag
    /// since), so it needs no capability gate.
    ///
    /// Callers must put this behind `ProfilesView`'s existing destructive
    /// confirmation dialog — `-y` skips Hermes's prompt, so Scarf's own
    /// prompt becomes the only one the user ever sees.
    ///
    /// v0.21.4+ can exit 1 AFTER the directory is gone, when only the
    /// identity settlement is pending (``HermesProfileDeleteVerdict``) — that
    /// reads as a completed delete carrying Hermes's follow-up sentence, not
    /// as a failure inviting a retry that can no longer succeed.
    func delete(_ profile: HermesProfile) {
        runAndReload(["profile", "delete", "-y", "--", profile.name], success: String(localized: "Deleted \(profile.name)"),
            partialSuccess: { output, exitCode in
                HermesProfileDeleteVerdict.settlementPendingWarning(output: output, exitCode: exitCode)
            }
        )
    }

    /// The banner for a delete that completed with pending identity
    /// settlement. A `static` so the sentence is reachable from a test.
    nonisolated static func completedWithWarning(_ success: String, warning: String) -> String {
        "\(success) — \(warning)"
    }

    /// Export always lands on **this Mac**, whichever host Hermes runs on
    /// (gh#132) — matching Sessions export. Local contexts hand the panel
    /// path straight to the CLI (it runs here). Remote contexts export to
    /// a host-side scratch path, stream the archive down, and clean up.
    ///
    /// The destination is normalised to `.tar.gz` first. `export_profile`
    /// strips only `.tar.gz` / `.tgz` from `--output` and then has
    /// `make_targz` append `.tar.gz` — so a `foo.zip` destination makes
    /// the CLI write `foo.zip.tar.gz` and leave the requested path empty,
    /// while still exiting 0.
    func export(_ profile: HermesProfile, to url: URL) {
        let outputPath = HermesProfileArchive.normalizedOutputPath(url.path)
        guard context.isRemote else {
            runAndReload(["profile", "export", "--output", outputPath, "--", profile.name], success: String(localized: "Exported"))
            return
        }
        message = "Exporting \(profile.name)…"
        let name = profile.name
        Task.detached { [fileService, context, self] in
            let transport = context.makeTransport()
            let result = await RemoteProfileExport.run(
                profileName: name,
                destination: URL(fileURLWithPath: outputPath),
                runCLI: { args, timeout in fileService.runHermesCLI(args: args, timeout: timeout) },
                streamFile: { path in
                    // Login shell for PATH parity with the rest of the
                    // remote CLI surface; the path is generated, not
                    // user input, so it needs no quoting.
                    transport.streamRawBytes(executable: "/bin/bash", args: ["-lc", "cat \(path)"])
                },
                removeRemote: { path in
                    _ = try? transport.runProcess(
                        executable: "/bin/sh", args: ["-c", "rm -f \(path)"], stdin: nil, timeout: 15)
                },
                onProgress: { written in
                    let progress = "Exporting \(name) — \(written.formatted(.byteCount(style: .file)))…"
                    Task { @MainActor [weak self] in self?.message = progress }
                }
            )
            await MainActor.run {
                self.message = result.message
                guard result.succeeded else { return }
                // Success clears itself; a failure stays until the next
                // action so it can't be missed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.message == result.message { self?.message = nil }
                }
            }
        }
    }

    func `import`(from path: String) {
        runAndReload(["profile", "import", "--", path], success: String(localized: "Imported"))
    }

    /// The one useful line out of a CLI failure. Hermes is Python, so a
    /// crash arrives as a traceback whose *last* line is the actual error —
    /// the first 120 characters are just "Traceback (most recent call
    /// last):" and stack frames (gh#131). Same reduction as Sessions export.
    static func failureMessage(_ output: String) -> String {
        let last = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let last, !last.isEmpty else { return "Failed (no output)." }
        return "Failed: \(last.prefix(200))"
    }

    /// Run a profile mutation and reload the list.
    ///
    /// `success` arrives ALREADY LOCALIZED from the caller (P54, round-6):
    /// three call sites passed a bare literal, so "Renamed" / "Exported" /
    /// "Imported" / "Deleted <name>" reached the banner in English on every
    /// locale. `String(localized:)` at the call site is what puts them in the
    /// catalogue — extraction is a compile-time scan of the literal, so
    /// wrapping the PARAMETER here would localize nothing.
    ///
    /// `partialSuccess` lets one verb (v0.21.4 `profile delete`) name a
    /// non-zero exit that nonetheless completed; it returns the warning to
    /// show beside `success`, or `nil` for a real failure. Such a banner
    /// stays up until the next action, like a failure, so the follow-up
    /// command in it can be read and copied.
    private func runAndReload(
        _ args: [String],
        success: String,
        partialSuccess: (@Sendable (_ output: String, _ exitCode: Int32) -> String?)? = nil
    ) {
        Task.detached { [cliRunner, self] in
            let result = await OffPool.run {
                cliRunner(args, 60)
            }
            let warning = partialSuccess?(result.output, result.exitCode)
            await MainActor.run {
                if let warning {
                    self.message = Self.completedWithWarning(success, warning: warning)
                    self.load()
                    return
                }
                self.message = result.exitCode == 0 ? success : Self.failureMessage(result.output)
                self.load()
                // P7e: capture what THIS action put up and only clear that
                // exact text. A bare `self?.message = nil` after the fixed
                // delay wipes whatever is on screen when the timer fires —
                // including a later action's persistent
                // `completedWithWarning` banner (never scheduled its own
                // clear, above) landing inside this one's 3s window.
                let shown = self.message
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.message == shown else { return }
                    self.message = nil
                }
            }
        }
    }

    /// Parse `hermes profile list` output into rows plus the `◆`-marked
    /// name. The parsing itself lives in ScarfCore (`HermesProfileList`) so
    /// ScarfGo uses the same rules (S13-F4). The marker is the process's own
    /// profile, which is the server's active profile only for an unpinned
    /// local run — see ``resolveActive(parsed:markedActive:isRemote:hostActiveFile:)``.
    nonisolated static func parseProfileList(_ output: String) -> (profiles: [HermesProfile], active: String) {
        let rows = HermesProfileList.parse(output)
        let active = rows.last(where: \.isMarked)?.id ?? HermesProfileScope.defaultProfileName
        return (rows.map { HermesProfile(name: $0.id, isActive: $0.isMarked, path: "") }, active)
    }

    /// The server's active profile for the list (S13-F3).
    ///
    /// Locally, `profile list` runs unpinned, so Hermes re-homes to the
    /// sticky `active_profile` and the `◆` marker names it: keep the parse
    /// as is. Remotely, every hermes call is pinned to the window's profile
    /// (`HERMES_HOME=` for a named one, `-p default` for the root), and the
    /// marker follows the process's home (`get_active_profile_name`,
    /// `hermes_cli/profiles.py:1941-1955` @ v2026.9.24), so it always marks
    /// the VIEWED profile. There the answer comes from `<root>/active_profile`
    /// (`hostActiveFile`; absent = default, unreadable = no badge), the way
    /// ScarfGo does it.
    nonisolated static func resolveActive(
        parsed: [HermesProfile],
        markedActive: String,
        isRemote: Bool,
        hostActiveFile: HostActiveFile
    ) -> (profiles: [HermesProfile], active: String?) {
        guard isRemote else { return (parsed, markedActive) }
        let active: String?
        switch hostActiveFile {
        case .missing: active = HermesProfileList.activeProfile(fromFileContents: nil)
        case .contents(let text): active = HermesProfileList.activeProfile(fromFileContents: text)
        // Don't assert what we don't know: the marker would name the viewed
        // profile, and "default" would be a guess.
        case .unreadable: active = nil
        }
        return (parsed.map { HermesProfile(name: $0.name, isActive: $0.name == active, path: $0.path) }, active)
    }

    /// Read the remote `<root>/active_profile` with one `cat`, so a missing
    /// file (the server is on default) can be told apart from a failed read.
    /// `ServerContext.readText` can't: its `fileExists` check reports a
    /// transport failure as "no file", which would badge `default` on a guess.
    nonisolated static func readHostActiveFile(context: ServerContext) -> HostActiveFile {
        let path = HermesProfileScope.rootHome(forHome: context.paths.home) + "/active_profile"
        guard let result = try? context.makeTransport().runProcess(
            executable: "cat", args: [path], stdin: nil, timeout: 15) else { return .unreadable }
        return classifyHostActiveRead(exitCode: result.exitCode, stdout: result.stdoutString, stderr: result.stderrString)
    }

    /// `cat`'s outcome → ``HostActiveFile``. Pure for tests.
    nonisolated static func classifyHostActiveRead(exitCode: Int32, stdout: String, stderr: String) -> HostActiveFile {
        if exitCode == 0 { return .contents(stdout) }
        if stderr.contains("No such file or directory") { return .missing }
        return .unreadable
    }

    /// What reading `<root>/active_profile` produced.
    enum HostActiveFile: Sendable, Equatable {
        /// No file: the server is on the default profile.
        case missing
        case contents(String)
        /// The read failed; the server's active profile is unknown.
        case unreadable
    }
}
