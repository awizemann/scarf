import CryptoKit
import Foundation
import ScarfCore
import os

/// Registers the bundled `scarf-projects` MCP server into the LOCAL
/// Hermes config at every launch.
///
/// Unconditional and untoggled by decision: the server is how agents are
/// meant to touch projects, and a setting that turns it off is a setting
/// that leaves an agent hand-appending rows to `projects.json` — the exact
/// failure the projects-first-class work exists to end.
///
/// **Idempotent.** A launch where the entry already points at this
/// binary writes nothing at all, which matters because Hermes watches its
/// own config and this runs on every single launch.
///
/// **Re-points on relocation.** The `command` is an absolute path into
/// the app bundle, so moving Scarf.app (Downloads → Applications, or a
/// Sparkle update landing elsewhere) would otherwise leave Hermes
/// spawning a binary that no longer exists. The path is re-asserted each
/// launch, in place, so the user's own edits to the entry — tool filters,
/// timeouts, env — survive; remove-and-re-add would discard them.
///
/// **Pinned to the profile that owns the entry.** The entry's `args` are
/// `--hermes-home <that profile's home>` (written by the in-place patcher,
/// not `mcp add --args` — see the add path for why). Hermes launches stdio MCP
/// servers with a filtered environment — PATH/HOME/USER/LANG/LC_ALL/TERM/
/// SHELL/TMPDIR and `XDG_*` only (`tools/mcp_tool_config.py:74,111-119` @
/// v2026.9.24) — so `HERMES_HOME` never reaches the server, and without the
/// argument it fell back to the sticky `active_profile`: a `hermes -p work`
/// agent registering a project wrote into whichever profile happened to be
/// active. Because `hermes profile create --clone` copies config.yaml
/// (`hermes_cli/profiles.py:35`), a clone inherits its source's pin; the
/// launch pass therefore also re-pins existing entries in the other local
/// profiles (never adding one there).
///
/// **Local only.** An MCP server runs where the agent runs, and the
/// bundled binary is a Mach-O for this Mac. SSH contexts are skipped
/// entirely; remote hosts keep the skill-driven fallback.
/// `nonisolated` on the whole type, deliberately: the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (SE-0466), which would otherwise
/// make `init` — and, invisibly, its DEFAULT ARGUMENTS — main-actor-isolated,
/// so the charter-C10 detached call in `scarfApp` could not construct one.
/// Nothing here touches UI or main-actor state; every member is blocking
/// transport/subprocess work that belongs off-main.
nonisolated struct ProjectsMCPRegistrar: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectsMCPRegistrar")

    /// The config key, and the name agents see. Stable forever: renaming
    /// it strands the old entry in every user's config.
    static let serverName = "scarf-projects"

    /// Where the executable lands in the bundle — see the app target's
    /// "Embed scarf-projects-mcp" copy-files phase.
    static let helperName = "scarf-projects-mcp"

    let context: ServerContext
    /// Injectable for tests; production resolves the running bundle.
    let binaryURL: URL?
    /// Injectable for tests so a suite never writes the real defaults.
    let unmanageableMarker: UnmanageableMarker

    init(
        context: ServerContext = .local,
        binaryURL: URL? = nil,
        unmanageableMarker: UnmanageableMarker = UnmanageableMarker()
    ) {
        self.context = context
        self.binaryURL = binaryURL
        self.unmanageableMarker = unmanageableMarker
    }

    /// The bundled helper, or `nil` when it isn't there — a developer
    /// build that predates the copy phase, or a stripped bundle. Absence
    /// is a no-op, never an error dialog: Scarf works fine without it.
    static func bundledBinaryURL(bundle: Bundle = .main) -> URL? {
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(helperName)"),
            bundle.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Why this copy of Scarf must NOT claim the user's config, or `nil`
    /// when it may.
    ///
    /// The registration re-points `command` at whatever bundle is running,
    /// which is right for the installed app and wrong for every other copy
    /// on this Mac. `scripts/build-detached.sh` installs a dev copy at
    /// `/Applications/scarf-dev.app` and agents run test copies out of
    /// `/tmp` and DerivedData: without this guard, every launch of any of
    /// them rewrites `~/.hermes/config.yaml` — churn on a file Hermes
    /// watches — and the `/tmp` and DerivedData ones point the user's
    /// agents at a binary the next clean build deletes.
    static func transientBundleReason(_ path: String) -> String? {
        let transientRoots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        if transientRoots.contains(where: { path.hasPrefix($0) }) {
            return "running from a temporary build location — leaving the Hermes config alone"
        }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return "running from a build directory — leaving the Hermes config alone"
        }
        // The dev copy is a stable path, so it WORKS — but registering it
        // makes the dev and release copies fight over the entry on every
        // launch. The installed app wins by default.
        //
        // Matched on the BUNDLE NAME, not on the literal `-dev.app/`: this
        // machine has `/Applications/scarf-dev.app` AND
        // `/Applications/scarf-dev-next.app`, and only the first was caught
        // — so the second re-pointed `command` at itself on every launch
        // while the installed app re-pointed it back, a rewrite war on a
        // file Hermes watches. Bundle id can't tell them apart:
        // `build-detached.sh` keeps `com.scarf.app` on purpose so iCloud
        // keeps working.
        if let bundle = devBundleName(in: path) {
            return "running the dev copy (\(bundle)) — leaving the Hermes config to the installed app"
        }
        return nil
    }

    /// The `.app` bundle name in `path` when it names a dev build, else nil.
    ///
    /// "Dev" is a whole word in the bundle name — `scarf-dev.app`,
    /// `scarf-dev-next.app`, `Scarf Dev.app` — so a user whose app is called
    /// `Devon.app` (or who keeps Scarf under `~/Developer/`) is not mistaken
    /// for one. Only the bundle name is examined; the folders above it are
    /// somebody's filing system, not a statement about the build.
    static func devBundleName(in path: String) -> String? {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            let name = component.dropLast(".app".count).lowercased()
            let tokens = name.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" || $0 == "." })
            if tokens.contains("dev") { return String(component) }
        }
        return nil
    }

    // MARK: - "Don't ask again until the file changes"

    /// SHA-256 over the current `config.yaml` AND the binary path we would
    /// register, or `nil` when the config can't be read (which is also the
    /// first-launch case — there is nothing to remember).
    ///
    /// The binary path is in the key because not every failure is the file's
    /// fault: a broken `hermes` install fails identically on a perfectly good
    /// config, and keying on the config alone would latch that failure until
    /// something happened to edit a file nobody has a reason to edit. Folding
    /// in the target path means a Sparkle update, a move to /Applications, or
    /// any reinstall that relocates the bundle un-latches it on its own.
    static func configFingerprint(context: ServerContext, targetPath: String) -> String? {
        let transport = context.makeTransport()
        guard var data = try? transport.readFile(context.paths.configYAML) else { return nil }
        data.append(Data(("\n" + targetPath).utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The one thing standing between a config Scarf cannot manage and a
    /// 90-second subprocess on every single launch, forever.
    ///
    /// When the parser can't find the entry — a CRLF file, a quoted key, a
    /// shape the patcher refuses — the registrar concludes the server is
    /// absent and shells `hermes mcp add`, which fails the same way every
    /// time. That is a minute and a half of a spawned CLI per launch, on a
    /// background task nobody is watching, producing nothing.
    ///
    /// Keyed on the config's CONTENT, not on a "we gave up" boolean: the
    /// moment the user (or Hermes, or another tool) changes the file, the
    /// fingerprint changes and Scarf tries again on its own. There is no
    /// state to reset by hand and no way for the marker to outlive the
    /// problem it describes.
    /// `nonisolated` for the same reason as the enclosing type: nested types do
    /// not inherit the outer declaration's isolation opt-out, and this type's
    /// `init` is a default argument of `ProjectsMCPRegistrar.init`.
    nonisolated struct UnmanageableMarker: Sendable {
        private let key = "ProjectsMCPRegistrar.unmanageableConfigSHA256"
        private let defaults: @Sendable () -> UserDefaults

        init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
            self.defaults = defaults
        }

        func matches(_ fingerprint: String) -> Bool {
            defaults().string(forKey: key) == fingerprint
        }

        func record(_ fingerprint: String?) {
            guard let fingerprint else { return }
            defaults().set(fingerprint, forKey: key)
        }

        func clear() {
            guard defaults().string(forKey: key) != nil else { return }
            defaults().removeObject(forKey: key)
        }
    }

    enum Outcome: Equatable {
        /// No bundled binary (or a remote context) — nothing attempted.
        case skipped(String)
        /// The entry was created via `hermes mcp add`.
        case added(path: String)
        /// The entry existed with a stale `command`; re-pointed in place.
        case repointed(from: String, to: String)
        /// The command was right but the `--hermes-home` pin was missing or
        /// named another home; the args were rewritten in place.
        case repinned(home: String)
        /// Already correct. The common case, and it writes nothing.
        case unchanged(path: String)
        case failed(String)
    }

    /// The arguments every registration carries: the home the entry's own
    /// profile lives at. `main.swift` requires it absolute and existing.
    static func registrationArgs(home: String) -> [String] {
        ["--hermes-home", home]
    }

    /// Blocking transport + subprocess work. Callers run it off-main
    /// (charter C10) — `scarfApp` does, on a detached utility task.
    @discardableResult
    nonisolated func ensureRegistered() -> Outcome {
        guard !context.isRemote else {
            return .skipped("remote context — the bundled binary only runs on this Mac")
        }
        // An injected path that isn't executable is treated exactly like a
        // missing one: registering a command Hermes cannot spawn would
        // turn a no-op into a broken entry the user has to find and
        // delete.
        guard let binary = binaryURL ?? Self.bundledBinaryURL(),
              FileManager.default.isExecutableFile(atPath: binary.path)
        else {
            return .skipped("no bundled \(Self.helperName) in this build")
        }
        let path = binary.path

        if binaryURL == nil, let reason = Self.transientBundleReason(path) {
            return .skipped(reason)
        }

        // Other local profiles first, and independently: their entries are
        // repaired whatever happens to the active one below.
        repinOtherProfiles(binaryPath: path)
        let expectedArgs = Self.registrationArgs(home: context.paths.home)

        let fileService = HermesFileService(context: context)
        let existing = fileService.loadMCPServers().first { $0.name == Self.serverName }

        // A config we already failed on, unchanged since. See
        // `unmanageableMarker`.
        let configFingerprint = Self.configFingerprint(context: context, targetPath: path)
        if let configFingerprint, unmanageableMarker.matches(configFingerprint) {
            return .skipped(
                "this Hermes config could not be updated on a previous launch and hasn't changed since"
            )
        }

        guard let existing else {
            // Creation goes through `hermes mcp add`, the argv Scarf
            // already ships and has verified against Hermes's argparse
            // (`hermes mcp add <name> --command <cmd>`, v0.21.0) — not a
            // second hand-written YAML entry writer.
            //
            // Added WITHOUT args, then pinned by the in-place patcher. The
            // pin can't ride on `--args`: it only became `nargs=REMAINDER`
            // in v2026.6.19 (v0.17.0, commit dca11b6650); before that it was
            // `nargs="*"`, and `--args --hermes-home <p>` fails argparse with
            // "unrecognized arguments". The bare add is the argv every
            // supported host already accepted; the probe it runs starts the
            // server unpinned, which falls back to the local home and still
            // answers the handshake.
            let result = fileService.addMCPServerStdio(
                name: Self.serverName,
                command: path,
                args: []
            )
            guard result.exitCode == 0 else {
                Self.logger.warning(
                    "hermes mcp add \(Self.serverName, privacy: .public) failed: \(result.output, privacy: .public)"
                )
                // Re-read: `hermes mcp add` is an external process that can
                // rewrite the config even on a non-zero exit, and recording
                // the pre-spawn hash would leave the marker never matching —
                // the 90-second spawn back on every launch, which is the one
                // thing this exists to stop.
                unmanageableMarker.record(
                    Self.configFingerprint(context: context, targetPath: path)
                )
                return .failed(result.output)
            }
            Self.logger.info("registered \(Self.serverName, privacy: .public) at \(path, privacy: .public)")
            unmanageableMarker.clear()
            if !fileService.setMCPServerArgs(name: Self.serverName, args: expectedArgs) {
                // The entry exists and works unpinned; the next launch takes
                // the re-pin path below and tries again.
                Self.logger.warning(
                    "registered \(Self.serverName, privacy: .public) but couldn't pin it to \(self.context.paths.home, privacy: .public)"
                )
            }
            return .added(path: path)
        }

        guard let currentCommand = existing.command else {
            // The entry exists but isn't a stdio server — a user's own
            // URL-based server squatting the name. Leave it alone: it is
            // theirs, and overwriting it would break whatever it serves.
            return .skipped(
                "an MCP server named \(Self.serverName) already exists and is not a stdio server"
            )
        }
        // Exact match: the entry is Scarf's, and the server accepts no other
        // arguments, so anything else in `args` is replaced by the pin.
        let argsPinned = existing.args == expectedArgs
        guard currentCommand != path || !argsPinned else {
            unmanageableMarker.clear()
            return .unchanged(path: path)
        }

        if currentCommand == path {
            // Only the pin is wrong (an entry from an older Scarf, or one a
            // profile clone copied from another home).
            guard fileService.setMCPServerArgs(name: Self.serverName, args: expectedArgs),
                  fileService.loadMCPServers().first(where: { $0.name == Self.serverName })?.args
                    == expectedArgs
            else {
                unmanageableMarker.record(
                    Self.configFingerprint(context: context, targetPath: path)
                )
                return .failed("could not pin \(Self.serverName) to \(context.paths.home)")
            }
            unmanageableMarker.clear()
            Self.logger.info(
                "pinned \(Self.serverName, privacy: .public) to \(self.context.paths.home, privacy: .public)"
            )
            return .repinned(home: context.paths.home)
        }

        guard fileService.setMCPServerCommand(name: Self.serverName, command: path),
              argsPinned || fileService.setMCPServerArgs(name: Self.serverName, args: expectedArgs)
        else {
            // The patcher refused (a shape it won't touch) or its read-back
            // failed and it restored the file. Either way the next launch
            // would refuse identically — mark it and stop asking.
            unmanageableMarker.record(configFingerprint)
            return .failed("could not re-point \(Self.serverName) to \(path)")
        }
        // `patchMCPServerField` reports success even when the write itself
        // failed (it logs and swallows), so confirm by reading back — a
        // re-point that silently didn't happen leaves Hermes spawning a
        // binary that isn't there, and this is the ONE launch pass that
        // would have caught it.
        let writtenEntry = fileService.loadMCPServers().first { $0.name == Self.serverName }
        let written = writtenEntry?.command
        guard written == path, writtenEntry?.args == expectedArgs else {
            unmanageableMarker.record(
                Self.configFingerprint(context: context, targetPath: path)
            )
            return .failed(
                "re-point of \(Self.serverName) did not stick (config still says "
                    + "\(written ?? "nothing"))"
            )
        }
        unmanageableMarker.clear()
        Self.logger.info(
            "re-pointed \(Self.serverName, privacy: .public): \(currentCommand, privacy: .public) → \(path, privacy: .public)"
        )
        return .repointed(from: currentCommand, to: path)
    }

    /// Re-assert command and pin on the `scarf-projects` entries that
    /// ALREADY exist in the other local profiles' configs. Never adds one —
    /// which profiles get the server is decided by launching Scarf with that
    /// profile active, exactly as before. Only an entry whose command is a
    /// `scarf-projects-mcp` binary is touched, so a user's own server that
    /// squats the name is left alone. Best effort: a profile we can't patch
    /// is logged and skipped.
    nonisolated func repinOtherProfiles(binaryPath: String) {
        let activeHome = context.paths.home
        let root = HermesProfileScope.rootHome(forHome: activeHome)
        var names: [String?] = [nil]  // the root (default) profile
        if let listed = try? FileManager.default.contentsOfDirectory(atPath: root + "/profiles") {
            names += listed.sorted().filter { HermesProfileScope.isValidName($0) }.map { Optional($0) }
        }
        for name in names {
            let profileContext = context.pinnedToProfile(name)
            let home = profileContext.paths.home
            guard home != activeHome,
                  FileManager.default.fileExists(atPath: profileContext.paths.configYAML)
            else { continue }
            let service = HermesFileService(context: profileContext)
            guard let entry = service.loadMCPServers().first(where: { $0.name == Self.serverName }),
                  let command = entry.command,
                  (command as NSString).lastPathComponent == Self.helperName
            else { continue }
            let args = Self.registrationArgs(home: home)
            let commandOK = command == binaryPath
                || service.setMCPServerCommand(name: Self.serverName, command: binaryPath)
            let argsOK = entry.args == args
                || service.setMCPServerArgs(name: Self.serverName, args: args)
            if !(commandOK && argsOK) {
                Self.logger.warning(
                    "couldn't re-pin \(Self.serverName, privacy: .public) in \(profileContext.paths.configYAML, privacy: .public)"
                )
            }
        }
    }
}
