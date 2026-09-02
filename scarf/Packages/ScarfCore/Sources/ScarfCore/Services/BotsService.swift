import Foundation

/// The Bot Mode domain layer: roster scanning, identity read/write, avatar
/// loading, and typed `hermes profile` lifecycle invocations.
///
/// **Everything goes through `ServerTransport`**, so the same code reads a
/// local `~/.hermes` and a remote one over SSH. There is no `FileManager` and
/// no `Process` in this file: a second, local-only path would be a silent
/// remote-host bug of exactly the kind Scarf keeps finding in its own history.
///
/// **A bot is a profile**, so the roster is the profile roster — the root home
/// (which Hermes calls `"default"`) plus every directory under
/// `<root>/profiles/`, mirroring `tools/bot_mode_probe.py:79-92` (`_roster`).
/// Profiles that are not bot-managed are returned too, marked
/// ``HermesBotIdentity/isBotManaged`` `false`, because "make this profile a
/// bot" is a real action and a roster that hides the candidates cannot offer
/// it.
public struct BotsService: Sendable {

    private let transport: any ServerTransport
    private let paths: HermesPathSet
    private let capabilities: HermesCapabilities
    private let prefersBatchedScan: Bool

    /// Ceiling on a single `profile.yaml` read. The file is metadata *about* a
    /// profile and Hermes keeps it "deliberately tiny"
    /// (`hermes_cli/profiles.py:907-918`); the gateway additionally caps the
    /// whole `ui_meta` block at 64KB. 1MB is two orders of magnitude of
    /// headroom and still bounds what a corrupt or hostile file can pull
    /// across an SSH channel into memory.
    public static let maxProfileYAMLBytes = 1_048_576

    /// Timeout for the batched roster script. Deliberately short: this runs on
    /// the first-paint path's critical section, and the fallback (the per-file
    /// scan) is *correct*, merely slower — so waiting a long time for the fast
    /// path is the worst of both.
    public static let batchedScanTimeout: TimeInterval = 20

    /// - Parameter prefersBatchedScan: whether ``rosterEntries()`` should try
    ///   the one-round-trip script first. Set for remote contexts only. A
    ///   local home's per-file scan is a handful of `FileManager` calls with
    ///   no round trip to save, so spawning `/bin/sh` for it would be slower
    ///   *and* a second code path to keep in parity — the audit's finding is
    ///   about SSH latency, not about file I/O.
    public init(
        transport: any ServerTransport,
        paths: HermesPathSet,
        capabilities: HermesCapabilities,
        prefersBatchedScan: Bool = false
    ) {
        self.transport = transport
        self.paths = paths
        self.capabilities = capabilities
        self.prefersBatchedScan = prefersBatchedScan
    }

    // MARK: - Layout

    /// The root Hermes home for this connection. `paths.home` may already be
    /// scoped to a named profile (Scarf can point a window at one), and
    /// `profiles/` only ever exists at the root — so every roster path is
    /// derived from here, never from `paths.home` directly.
    public var rootHome: String { HermesProfileScope.rootHome(forHome: paths.home) }

    /// `<root>/profiles`.
    public var profilesDirectory: String { rootHome + "/profiles" }

    /// Whether `name` is a profile id Scarf will build a path from: either the
    /// `default` sentinel or a name matching Hermes' own
    /// `^[a-z0-9][a-z0-9_-]{0,63}$`. This is the path-injection guard AND a
    /// data-safety guard: `HermesProfileScope.resolveHome` fails *safe* to the
    /// root home for an invalid name, which for a read is right and for a
    /// write would mean editing the default profile's file while the caller
    /// believed it was editing `../../etc`.
    public static func isAddressableProfile(_ name: String) -> Bool {
        name == HermesProfileScope.defaultProfileName || HermesProfileScope.isValidName(name)
    }

    /// The directory of a profile by canonical id.
    public func directory(forProfile name: String) -> String {
        HermesProfileScope.resolveHome(baseHome: rootHome, profile: name)
    }

    /// `<profile_dir>/profile.yaml`.
    public func profileYAMLPath(forProfile name: String) -> String {
        directory(forProfile: name) + "/profile.yaml"
    }

    // MARK: - Scanning

    /// Every profile on the host, in `_roster` order: `default` first, then
    /// named profiles sorted by id (the CLI and the probe both sort, so the
    /// roster is stable across clients).
    ///
    /// A profile whose `profile.yaml` is missing, oversized, or malformed
    /// still appears — as an unmanaged identity. Hermes degrades this way on
    /// purpose (`read_profile_meta` swallows every exception so "a corrupt
    /// profile.yaml on an unrelated profile must not break `hermes profile
    /// list`"), and so must Scarf: one bad file cannot be allowed to empty
    /// the roster.
    public func scan() -> [HermesBotIdentity] {
        var out: [HermesBotIdentity] = [identity(forProfile: HermesProfileScope.defaultProfileName)]
        for name in namedProfiles() {
            out.append(identity(forProfile: name))
        }
        return out
    }

    /// Named profile ids, sorted. Invalid directory names are skipped — they
    /// can't be addressed by `hermes -p` or by a path Scarf would build.
    public func namedProfiles() -> [String] {
        guard transport.fileExists(profilesDirectory) else { return [] }
        guard let entries = try? transport.listDirectory(profilesDirectory) else { return [] }
        return entries
            .filter { HermesProfileScope.isValidName($0) }
            .filter { transport.stat(profilesDirectory + "/" + $0)?.isDirectory == true }
            .sorted()
    }

    /// Read one profile's identity. Never throws; see ``scan()``.
    public func identity(forProfile name: String) -> HermesBotIdentity {
        let dir = directory(forProfile: name)
        let path = profileYAMLPath(forProfile: name)
        let empty = HermesBotIdentity(profileName: name, profileDirectory: dir)
        guard let yaml = readBoundedText(path, limit: Self.maxProfileYAMLBytes) else { return empty }
        return HermesBotProfileYAML.parse(yaml, profileName: name, profileDirectory: dir)
    }

    // MARK: - Roster entries (Phase B P2)

    /// The roster plus each profile's avatar *stat* — everything a roster row
    /// needs to paint, and nothing it doesn't.
    ///
    /// Tries the batched script first on a transport where a round trip is the
    /// cost (see ``init(transport:paths:capabilities:prefersBatchedScan:)``),
    /// and falls back to ``rosterEntriesPerFile()`` on any refusal. The two
    /// paths are held to identical results by
    /// `BotModePhaseBP2Tests.batchedScanMatchesPerFileScan`.
    public func rosterEntries() async -> [BotRosterEntry] {
        if prefersBatchedScan, let batched = await batchedRosterEntries() {
            return batched
        }
        return rosterEntriesPerFile()
    }

    /// The per-file roster scan — one `stat`/`read` per profile, plus up to
    /// three avatar `fileExists` probes. Always correct, and the reference
    /// semantics the batched path is diffed against.
    public func rosterEntriesPerFile() -> [BotRosterEntry] {
        scan().map { identity in
            BotRosterEntry(identity: identity, avatar: avatarStat(forProfile: identity.profileName))
        }
    }

    /// One `sh` round trip for the whole roster, or `nil` when the host, the
    /// transport, or the output says the answer can't be trusted.
    func batchedRosterEntries() async -> [BotRosterEntry]? {
        let script = BotsRosterScan.script(
            rootHome: rootHome,
            maxYAMLBytes: Self.maxProfileYAMLBytes
        )
        guard let result = try? await transport.streamScript(script, timeout: Self.batchedScanTimeout),
              result.exitCode == 0 else {
            return nil
        }
        return BotsRosterScan.parse(result.stdoutString, rootHome: rootHome)
    }

    /// The avatar file's path and stat, without reading its bytes.
    public func avatarStat(forProfile name: String) -> BotAvatarStat? {
        guard let found = avatarPath(forProfile: name) else { return nil }
        let stat = transport.stat(found.path)
        return BotAvatarStat(
            path: found.path,
            mime: found.mime,
            size: stat?.size ?? 0,
            mtime: Int64(stat?.mtime.timeIntervalSince1970 ?? 0)
        )
    }

    /// Read the bytes behind a stat the roster scan already produced.
    ///
    /// Split out from ``loadAvatar(forProfile:)`` so the roster never re-probes
    /// three extensions for a path it was just told: this is the call the view
    /// model makes *only* on a cache miss, one profile at a time, after the
    /// roster has already painted.
    public func loadAvatar(at stat: BotAvatarStat) throws -> HermesBotAvatar {
        if stat.size > Int64(HermesBotAvatar.maxBytes) {
            throw BotsError.avatarTooLarge(path: stat.path, size: Int(stat.size))
        }
        let data = try transport.readFile(stat.path)
        guard data.count <= HermesBotAvatar.maxBytes else {
            throw BotsError.avatarTooLarge(path: stat.path, size: data.count)
        }
        return HermesBotAvatar(data: data, mimeType: stat.mime, path: stat.path)
    }

    // MARK: - Avatars

    /// Whether an avatar file exists, without reading its bytes. Cheap enough
    /// for a roster paint; the bytes are not.
    public func hasAvatar(forProfile name: String) -> Bool {
        avatarPath(forProfile: name) != nil
    }

    /// The stored avatar path, probing extensions in the gateway's own order.
    public func avatarPath(forProfile name: String) -> (path: String, mime: String)? {
        let assets = directory(forProfile: name) + "/assets"
        for candidate in HermesBotAvatar.probeOrder {
            let path = assets + "/avatar." + candidate.ext
            if transport.fileExists(path) { return (path, candidate.mime) }
        }
        return nil
    }

    /// Load an avatar's bytes.
    ///
    /// - Returns: `nil` when the profile has no avatar.
    /// - Throws: ``BotsError/avatarTooLarge(path:size:)`` when the file
    ///   exceeds ``HermesBotAvatar/maxBytes``. The size is checked with a
    ///   `stat` **before** the read, so an oversized file is never pulled
    ///   across the transport at all — the difference between refusing a
    ///   200MB file and OOMing a window on a 200MB file.
    public func loadAvatar(forProfile name: String) throws -> HermesBotAvatar? {
        guard let found = avatarPath(forProfile: name) else { return nil }
        if let stat = transport.stat(found.path), stat.size > Int64(HermesBotAvatar.maxBytes) {
            throw BotsError.avatarTooLarge(path: found.path, size: Int(stat.size))
        }
        let data = try transport.readFile(found.path)
        // A transport whose `stat` is unavailable (or a file that grew between
        // the stat and the read) still must not slip past the cap.
        guard data.count <= HermesBotAvatar.maxBytes else {
            throw BotsError.avatarTooLarge(path: found.path, size: data.count)
        }
        return HermesBotAvatar(data: data, mimeType: found.mime, path: found.path)
    }

    // MARK: - Writing identity

    /// Persist an identity to `<profile_dir>/profile.yaml`.
    ///
    /// Read-merge-write: the file is re-read here, immediately before the
    /// write, and only the keys Scarf owns are changed. See
    /// ``HermesBotProfileYAML`` for the preservation contract and for the
    /// compare-and-swap caveat — this write has no interlock against a
    /// concurrent Hermes Desktop edit, so it must only ever run from an
    /// explicit user save.
    ///
    /// - Throws: ``BotsError/unsupported`` on a host below the Bot Mode floor
    ///   (writing a key that version of Hermes ignores would be an invisible
    ///   no-op the user reads as a save), ``BotsError/profileMissing(name:)``
    ///   when the profile directory isn't there, and
    ///   ``BotsError/unsafeToWrite(path:)`` when the file is in a shape the
    ///   writer refuses to edit.
    public func saveIdentity(_ identity: HermesBotIdentity) throws {
        guard capabilities.hasBotMode else { throw BotsError.unsupported }
        guard Self.isAddressableProfile(identity.profileName) else {
            throw BotsError.profileMissing(name: identity.profileName)
        }
        let dir = directory(forProfile: identity.profileName)
        guard transport.fileExists(dir) else { throw BotsError.profileMissing(name: identity.profileName) }

        let path = profileYAMLPath(forProfile: identity.profileName)
        // An ABSENT file is normal — Hermes creates profile.yaml lazily on the
        // first `describe`, so a profile that has never been described has
        // none. A file that exists but cannot be read is the opposite: reading
        // it as `""` and merging into that would REPLACE somebody's file with
        // a three-line stub. Refuse instead; the read path's "degrade to
        // empty" contract is for display only, never for a merge base.
        let exists = transport.fileExists(path)
        let current = readBoundedText(path, limit: Self.maxProfileYAMLBytes)
        guard let current = exists ? current : (current ?? "") else {
            throw BotsError.unsafeToWrite(path: path)
        }
        guard let updated = HermesBotProfileYAML.write(identity: identity, into: current) else {
            throw BotsError.unsafeToWrite(path: path)
        }
        guard let data = updated.data(using: .utf8) else { throw BotsError.unsafeToWrite(path: path) }
        try transport.writeFile(path, data: data)
    }

    // MARK: - Lifecycle (hermes profile …)

    /// A profile-lifecycle action, with its verified argv.
    ///
    /// Pinned against `hermes_cli/subcommands/profile.py` at the audited tag
    /// v2026.8.31 (Hermes 0.21.0), `build_profile_parser`:
    /// - `create <profile_name> [--clone] [--clone-all] [--clone-from SOURCE]
    ///   [--no-alias] [--no-skills] [--description TEXT]` (:29-64)
    /// - `delete <profile_name> [-y|--yes]` (:66-70)
    /// - `rename <old_name> <new_name>` (:123-131)
    ///
    /// These verbs long predate Bot Mode (profiles shipped in Hermes v0.11),
    /// so they carry no capability floor of their own.
    public enum Lifecycle: Sendable, Equatable {
        /// `--description` is threaded here rather than written to
        /// profile.yaml afterwards: `cmd_profile` persists it as the last step
        /// of create, so doing it in one invocation avoids a window where the
        /// profile exists with no role.
        ///
        /// Bare `--clone` (clone the *active* profile) is deliberately not
        /// exposed: which profile is active is ambient host state, and a bot
        /// roster that silently copies whatever it happens to be is a
        /// reproducibility trap. Clone from a named source, or from nothing.
        case create(name: String, cloneFrom: String?, cloneAll: Bool, noSkills: Bool, description: String?)
        /// **Destructive and irreversible.** `hermes profile delete` removes
        /// the profile directory — state.db, sessions, memories, .env, the
        /// lot. `--yes` is always passed because Scarf has no TTY to answer
        /// the prompt on; the confirmation is therefore entirely Scarf's
        /// responsibility, which is what ``isDestructive`` exists to force a
        /// caller to notice.
        case delete(name: String)
        /// For the `default` profile this sets a display name instead — the
        /// canonical id stays `default` (:123-131, and
        /// `profiles.py:2423-2435`). A UI that says "rename" to a user
        /// pointing at `default` is describing something else.
        case rename(from: String, to: String)

        public var argv: [String] {
            switch self {
            case .create(let name, let cloneFrom, let cloneAll, let noSkills, let description):
                var args = ["profile", "create", name]
                if cloneAll {
                    args.append("--clone-all")
                }
                if let cloneFrom, !cloneFrom.isEmpty {
                    // `--clone-from` implies `--clone` unless `--clone-all` is
                    // set, so `--clone` is never added alongside it.
                    args += ["--clone-from", cloneFrom]
                }
                if noSkills { args.append("--no-skills") }
                if let description, !description.trimmingCharacters(in: .whitespaces).isEmpty {
                    args += ["--description", description]
                }
                return args
            case .delete(let name):
                return ["profile", "delete", name, "--yes"]
            case .rename(let from, let to):
                return ["profile", "rename", from, to]
            }
        }

        /// `true` for actions that destroy user data. The UI must confirm
        /// these explicitly; the service will not.
        public var isDestructive: Bool {
            if case .delete = self { return true }
            return false
        }

        /// Every profile id this action names. Checked before the spawn so a
        /// malformed name fails in Scarf with a clear error instead of
        /// reaching argv — `rename`'s target in particular is a name Hermes
        /// will turn into a directory.
        public var profileNames: [String] {
            switch self {
            case .create(let name, let cloneFrom, _, _, _):
                return [name] + (cloneFrom.map { [$0] } ?? [])
            case .delete(let name): return [name]
            case .rename(let from, let to): return [from, to]
            }
        }
    }

    /// Run a lifecycle action. Returns the raw `ProcessResult` so the caller
    /// can surface the CLI's own stderr verbatim — Hermes' profile errors
    /// ("profile 'x' already exists", "cannot delete the active profile") are
    /// the actionable text, and a Scarf paraphrase would lose it.
    ///
    /// A non-zero exit is **not** thrown: it is a completed invocation
    /// carrying a refusal. Transport failures still throw.
    public func run(_ action: Lifecycle, timeout: TimeInterval = 120) throws -> ProcessResult {
        for name in action.profileNames where !Self.isAddressableProfile(name) {
            throw BotsError.profileMissing(name: name)
        }
        guard !action.isDestructive || capabilities.detected else {
            // Refusing a destructive action against an undetected host is
            // cheap insurance: if `hermes --version` didn't answer, Scarf
            // does not know what it is about to delete a profile with.
            throw BotsError.unsupported
        }
        return try transport.runProcess(
            executable: paths.hermesBinary,
            args: action.argv,
            stdin: nil,
            timeout: timeout
        )
    }

    // MARK: - Bounded reads

    /// Read a text file, refusing anything over `limit` **before** transferring
    /// it. Returns nil when absent, oversized, unreadable, or not UTF-8 —
    /// every one of which the caller treats as "no metadata", matching
    /// Hermes' own never-raises read path.
    private func readBoundedText(_ path: String, limit: Int) -> String? {
        guard transport.fileExists(path) else { return nil }
        if let stat = transport.stat(path), stat.size > Int64(limit) { return nil }
        guard let data = try? transport.readFile(path), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Failures the Bot Mode domain layer surfaces to the UI.
public enum BotsError: Error, Equatable, Sendable {
    /// The connected Hermes predates Bot Mode's storage format.
    case unsupported
    /// No directory for that profile id.
    case profileMissing(name: String)
    /// `profile.yaml` is in a shape the surgical writer refuses to edit.
    /// The caller must present the bot read-only rather than write anyway.
    case unsafeToWrite(path: String)
    /// The avatar exceeds the gateway's own 2MB ceiling and was not read.
    case avatarTooLarge(path: String, size: Int)
    /// A file exists but could not be turned into an editable buffer
    /// (unreadable, oversized, or not UTF-8). Distinct from "absent", which is
    /// normal: the caller must NOT fall back to an empty editor, because
    /// saving that would replace the real file with nothing. Phase B.
    case unsafeToRead(path: String)
    /// A value or dotted config key Scarf refuses to hand to
    /// `hermes config set/unset` — empty, flag-shaped, or carrying a character
    /// that would change which key is written. Phase B.
    case invalidValue(key: String)
}
