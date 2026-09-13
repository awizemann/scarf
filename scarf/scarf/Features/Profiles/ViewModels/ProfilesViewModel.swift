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

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }


    var profiles: [HermesProfile] = []
    var activeName: String = "default"
    var isLoading = false
    var message: String?
    var detailOutput: String = ""

    func load() {
        isLoading = true
        Task.detached { [fileService] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: ["profile", "list"], timeout: 20)
            }
            let (parsed, active) = Self.parseProfileList(result.output)
            await MainActor.run {
                self.isLoading = false
                self.profiles = parsed
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
    func delete(_ profile: HermesProfile) {
        runAndReload(["profile", "delete", "-y", "--", profile.name], success: String(localized: "Deleted \(profile.name)"))
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
    private func runAndReload(_ args: [String], success: String) {
        Task.detached { [fileService, self] in
            let result = await OffPool.run {
                fileService.runHermesCLI(args: args, timeout: 60)
            }
            await MainActor.run {
                self.message = result.exitCode == 0 ? success : Self.failureMessage(result.output)
                self.load()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.message = nil
                }
            }
        }
    }

    /// Parse `hermes profile list` output. Hermes emits a box-drawn Rich table:
    ///
    ///     Profile         Model    Gateway    Alias
    ///     ─────────────── ──────── ────────── ─────
    ///     ◆default        —        running    —
    ///     experimental    gpt-4    stopped    hermes-exp
    ///
    /// Active profiles are prefixed with `◆` (U+25C6). Columns are separated by
    /// whitespace; there are no vertical bars. We ignore box-drawing lines and
    /// the header row, then extract the name from column 0 of each data row.
    ///
    /// As of Hermes 0.20.5, the Profile column is rendered via
    /// `format_profile_label(name, display_name)` (hermes_cli/profiles.py):
    /// `f"{display_name} ({name})"` when a display name is set and differs
    /// from the canonical name, else the bare canonical name unchanged
    /// (byte-for-byte the pre-0.20.5 rendering). Note the display name comes
    /// *first* and the canonical id is the parenthesized part — the opposite
    /// order of a naive "name (extra)" read. Display names are free-form
    /// presentation text (any Unicode, including spaces/parens, up to 64
    /// chars) and are never argv-safe, whereas canonical profile ids are
    /// validated against `^[a-z0-9][a-z0-9_-]{0,63}$` (profiles.py
    /// `_PROFILE_ID_RE`) and can never themselves contain a space or a
    /// paren — so a parenthesized id-shaped token in the row is unambiguous.
    /// The row itself is printed as `f"{marker}{name:<15} {model:<28} {gw:<12}
    /// {alias:<12} {dist}"` (main.py) — fixed-width fields separated by a
    /// single literal space, so a field shorter than its width leaves a run
    /// of 2+ spaces before the next field while the label itself (a display
    /// name) may still contain single spaces that survive. We therefore
    /// split the row on runs of 2+ spaces to isolate field 0 (the Profile
    /// label) *before* searching for a `(canonical-id)` group — searching
    /// the whole line would also match an id-shaped parenthetical that
    /// happens to appear in the Model column (e.g. `gpt-4o (preview)`).
    /// Within field 0 we take the *last* such group, since the display name
    /// itself may contain an id-shaped parenthetical (e.g. "My (test)
    /// profile (myid)"); when no group is present in field 0 we fall back to
    /// its first whitespace token — field 0's bare canonical name, matching
    /// pre-0.20.5 hosts where no display-name suffix is ever rendered.
    nonisolated private static let profileIDParenPattern =
        try! NSRegularExpression(pattern: "\\(([a-z0-9][a-z0-9_-]{0,63})\\)")

    nonisolated static func parseProfileList(_ output: String) -> (profiles: [HermesProfile], active: String) {
        var results: [HermesProfile] = []
        var active = "default"
        var sawHeader = false

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Box-drawing separator rows: contain only ─ (U+2500) and whitespace.
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) { continue }
            // Header row (first non-empty, non-separator line in the table).
            if !sawHeader && line.lowercased().contains("profile") && line.lowercased().contains("gateway") {
                sawHeader = true
                continue
            }
            // Data row. Strip active marker first.
            var working = line
            var isActive = false
            if working.hasPrefix("◆") {
                isActive = true
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if working.hasPrefix("*") {
                isActive = true
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Isolate field 0 (the Profile label) by splitting on runs of 2+
            // spaces — the fixed-width column padding — so a paren group in
            // a later column (e.g. the Model field) can't be mistaken for
            // the canonical id.
            let fields = working.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let field0 = fields.first else { continue }
            var nameStr: String?
            let nsField0 = field0 as NSString
            let matches = Self.profileIDParenPattern.matches(
                in: field0, range: NSRange(location: 0, length: nsField0.length))
            if let lastMatch = matches.last {
                nameStr = nsField0.substring(with: lastMatch.range(at: 1))
            } else {
                let tokens = field0.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                nameStr = tokens.first
            }
            guard let name = nameStr else { continue }
            // Reject rows whose extracted name is something like "Tip:" or a localized
            // label — real profile names/ids are lowercase alphanumeric with - or _.
            // \A…\z, not ^…$: ICU's $ matches before a trailing newline
            // (SEC-L1), and this name becomes a `hermes -p` argument.
            guard name.range(of: "\\A[a-zA-Z0-9_-]+\\z", options: .regularExpression) != nil else { continue }
            if isActive { active = name }
            results.append(HermesProfile(name: name, isActive: isActive, path: ""))
        }
        return (results, active)
    }
}
