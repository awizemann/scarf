import Foundation
import ScarfCore
import os

// MARK: - Backend seam

/// Everything the Bots surface needs from the host, behind one protocol.
///
/// The real implementation (``LiveBotsBackend``) is a thin shell over B0's
/// `BotsService` plus the one write B0 deliberately left out (avatar bytes).
/// The seam exists so the view model's ordering, promote/demote and
/// editor round-trip logic are testable without a Hermes home, an SSH
/// transport, or a `hermes` binary on PATH.
protocol BotsBackend: Sendable {
    /// Every profile on the host, in `_roster` order.
    func scan() -> [HermesBotIdentity]
    /// One profile's identity, re-read from disk.
    func identity(forProfile name: String) -> HermesBotIdentity
    /// Avatar bytes, or nil when the profile has none.
    func loadAvatar(forProfile name: String) throws -> HermesBotAvatar?
    /// Read-merge-write of the three regions Scarf owns in `profile.yaml`.
    func saveIdentity(_ identity: HermesBotIdentity) throws
    /// Store avatar bytes at `<profile_dir>/assets/avatar.png`.
    func writeAvatar(_ data: Data, forProfile name: String) throws
    /// Run a `hermes profile …` lifecycle verb.
    func run(_ action: BotsService.Lifecycle) throws -> ProcessResult
}

/// `BotsBackend` over a real host.
struct LiveBotsBackend: BotsBackend {
    let transport: any ServerTransport
    let paths: HermesPathSet
    let capabilities: HermesCapabilities

    private var service: BotsService {
        BotsService(transport: transport, paths: paths, capabilities: capabilities)
    }

    init(context: ServerContext, capabilities: HermesCapabilities) {
        self.transport = context.makeTransport()
        self.paths = context.paths
        self.capabilities = capabilities
    }

    func scan() -> [HermesBotIdentity] { service.scan() }
    func identity(forProfile name: String) -> HermesBotIdentity { service.identity(forProfile: name) }
    func loadAvatar(forProfile name: String) throws -> HermesBotAvatar? { try service.loadAvatar(forProfile: name) }
    func saveIdentity(_ identity: HermesBotIdentity) throws { try service.saveIdentity(identity) }
    func run(_ action: BotsService.Lifecycle) throws -> ProcessResult { try service.run(action) }

    /// Write `avatar.png`, mirroring the gateway's `set_asset`: one canonical
    /// file per asset, with the other extensions cleared first so a stale
    /// `avatar.jpg` can never out-live the picture the user just chose.
    ///
    /// The 2MB ceiling is re-checked here even though the importer already
    /// downscales: this is the last gate before bytes cross the transport,
    /// and the gateway would reject anything larger anyway (error 4069).
    func writeAvatar(_ data: Data, forProfile name: String) throws {
        guard BotsService.isAddressableProfile(name) else {
            throw BotsError.profileMissing(name: name)
        }
        guard data.count <= HermesBotAvatar.maxBytes else {
            throw BotsError.avatarTooLarge(path: name, size: data.count)
        }
        let dir = service.directory(forProfile: name)
        guard transport.fileExists(dir) else { throw BotsError.profileMissing(name: name) }
        let assets = dir + "/assets"
        if !transport.fileExists(assets) {
            try transport.createDirectory(assets)
        }
        try transport.writeFile(assets + "/avatar.png", data: data)
        for candidate in HermesBotAvatar.probeOrder where candidate.ext != "png" {
            let stale = assets + "/avatar." + candidate.ext
            if transport.fileExists(stale) { try? transport.removeFile(stale) }
        }
    }
}

// MARK: - Rows

/// One roster row: an identity plus the avatar bytes, if any were loaded.
struct BotRow: Identifiable, Equatable {
    let identity: HermesBotIdentity
    /// Nil when the profile has no stored avatar (the generated fallback
    /// renders) *or* when its bytes haven't been loaded yet.
    var avatar: HermesBotAvatar?

    var id: String { identity.profileName }
    var isPinned: Bool { identity.pinned == true }
    var isHidden: Bool { identity.hidden == true }
}

// MARK: - Editor draft

/// The mutable half of a bot identity — exactly the fields this editor owns.
///
/// Deliberately *not* a whole `HermesBotIdentity`: an editor that round-trips
/// the full struct through a sheet would carry a stale snapshot of the keys
/// it never shows (`created`, `groups`, the legacy `group` scalar, and every
/// unmodeled key B0 preserves in `unknownMetaLines`) and write that snapshot
/// back over whatever landed in the file meanwhile. ``apply(to:)`` instead
/// stamps these seven fields onto an identity re-read at save time, so
/// everything else in the file is whatever the file currently says.
struct BotDraft: Equatable {
    var profileName: String
    var title: String
    var description: String
    var color: String
    var shape: String
    var pinned: Bool
    var hidden: Bool

    init(identity: HermesBotIdentity) {
        profileName = identity.profileName
        title = identity.title ?? identity.displayName
        description = identity.botDescription ?? identity.profileDescription
        color = identity.color ?? ""
        shape = identity.shape ?? ""
        pinned = identity.pinned ?? false
        hidden = identity.hidden ?? false
    }

    /// Stamp the edited fields onto `identity`, leaving every other key alone.
    ///
    /// Empty text clears the key rather than writing `""` — Hermes' own
    /// `write_profile_meta` drops an emptied `display_name` instead of
    /// persisting a blank, and a blank `color`/`shape` must fall back to the
    /// generated avatar rather than pin an empty string.
    /// Collapse a pasted multi-line value into one line. Applied to the
    /// fields Hermes and Scarf both treat as single-line labels (title,
    /// color, shape) — a `TextField` won't produce a newline, but a paste
    /// will, and a two-line "title" is nonsense in every surface that renders
    /// it. NOT applied to `description`: Hermes stores that through
    /// `yaml.safe_dump` and round-trips real newlines, so flattening it would
    /// destroy user content to work around a writer bug that
    /// `HermesBotProfileYAML.quoted` now handles correctly at the YAML layer.
    static func singleLine(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(to identity: inout HermesBotIdentity) {
        let trimmedTitle = Self.singleLine(title)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedColor = Self.singleLine(color)
        let trimmedShape = Self.singleLine(shape)

        // The editor writes one name and one blurb; they land in both the
        // bot block and the profile's own top-level keys so `hermes profile
        // list` and the kanban decomposer see the same text the roster does.
        identity.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        identity.displayName = trimmedTitle
        identity.botDescription = trimmedDescription.isEmpty ? nil : trimmedDescription
        identity.profileDescription = trimmedDescription
        // A human just typed this, so the "LLM wrote it" marker is stale.
        if !trimmedDescription.isEmpty { identity.descriptionIsAuto = false }

        identity.color = trimmedColor.isEmpty ? nil : trimmedColor
        identity.shape = trimmedShape.isEmpty ? nil : trimmedShape
        identity.pinned = pinned
        identity.hidden = hidden
        // Saving through this editor is what makes a profile a bot.
        identity.isBotManaged = true
    }
}

// MARK: - View model

/// Backing model for the Bots section — the roster of Hermes profiles seen
/// as bots, plus create/edit/promote/delete.
///
/// Coordinator-cached (t-aud24), so it lives exactly as long as the window's
/// server binding: `ContextBoundRoot` is `.id(context.id)`, which rebuilds
/// the coordinator — and therefore this view model and its transport — on a
/// server switch. There is no shared/static state here for that reason.
@Observable
@MainActor
final class BotsViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "BotsViewModel")

    let context: ServerContext
    /// Non-nil in tests; when set, `capabilities` changes never rebuild it.
    @ObservationIgnored private let injectedBackend: (any BotsBackend)?
    @ObservationIgnored private var backend: any BotsBackend

    /// Mirrored from the environment capability store by the view, the same
    /// way `CronView` mirrors its version flags: the store probes
    /// `hermes --version` asynchronously, so the first render can precede the
    /// answer. The `didSet` rebuilds the live backend because
    /// `BotsService.saveIdentity` refuses to write on a host below the floor.
    var capabilities: HermesCapabilities {
        didSet {
            guard injectedBackend == nil, capabilities != oldValue else { return }
            backend = LiveBotsBackend(context: context, capabilities: capabilities)
        }
    }

    var hasBotMode: Bool { capabilities.hasBotMode }

    init(
        context: ServerContext = .local,
        capabilities: HermesCapabilities = .empty,
        backend: (any BotsBackend)? = nil
    ) {
        self.context = context
        self.capabilities = capabilities
        self.injectedBackend = backend
        self.backend = backend ?? LiveBotsBackend(context: context, capabilities: capabilities)
    }

    // MARK: - State

    private(set) var rows: [BotRow] = []
    var isLoading = false
    var isWorking = false
    /// Transient success line in the header.
    var message: String?
    /// Verbatim failure text — CLI stderr where there is any, since Hermes'
    /// own profile errors carry the remedy and a paraphrase would lose it.
    var errorMessage: String?

    /// Selected profile id. A name (not an index) so a rescan that reorders
    /// or drops rows can never silently retarget an edit or a delete.
    var selectedProfileName: String? {
        didSet {
            guard selectedProfileName != oldValue else { return }
            // Switching bots tears the previous conversation down BEFORE
            // anything else can open a new one — this is the single choke
            // point that enforces "at most one live ACP subprocess".
            closeConversation()
        }
    }
    var showHiddenBots = false
    var showOtherProfiles = false

    @ObservationIgnored private var hasLoaded = false

    /// Guards against an older in-flight scan clobbering a newer one's
    /// result. Every mutating action ends in `load(force: true)`, so two
    /// scans overlapping is the normal case, not the exotic one — and a
    /// slow pre-delete scan landing after a fast post-delete scan would put
    /// the deleted bot back on screen. Same generation counter
    /// `HermesCapabilitiesStore` uses for the same reason.
    @ObservationIgnored private var loadGeneration = 0

    // MARK: - Derived roster

    /// Bot-managed, not hidden. Pinned first, then by display name.
    var bots: [BotRow] { Self.sortBots(rows.filter { $0.identity.isBotManaged && !$0.isHidden }) }

    /// Bot-managed but flagged `hidden` — collapsed behind a disclosure
    /// rather than dropped: Scarf can un-hide them, so hiding them
    /// irrecoverably would be a one-way door.
    var hiddenBots: [BotRow] { Self.sortBots(rows.filter { $0.identity.isBotManaged && $0.isHidden }) }

    /// Profiles with no `hermes-bots` block. Kept in scan order (`default`
    /// first, then sorted ids) — these are candidates to promote, not a
    /// roster to rank.
    var otherProfiles: [BotRow] { rows.filter { !$0.identity.isBotManaged } }

    /// The roster ordering, in one place so tests can pin it:
    /// pinned bots first, then case-insensitive by resolved title, with the
    /// canonical profile id as the tie-break so the order is total (two bots
    /// may legitimately share a title).
    static func sortBots(_ input: [BotRow]) -> [BotRow] {
        input.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            let l = lhs.identity.resolvedTitle
            let r = rhs.identity.resolvedTitle
            let comparison = l.localizedCaseInsensitiveCompare(r)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.identity.profileName < rhs.identity.profileName
        }
    }

    var selectedRow: BotRow? {
        guard let selectedProfileName else { return nil }
        return rows.first { $0.identity.profileName == selectedProfileName }
    }

    /// True when the host supports Bot Mode and no profile is bot-managed —
    /// the bootstrap state, which must offer "Create Bot" rather than hide
    /// the section (`hasBotMode` is a version gate, never a data gate).
    var isEmptyRoster: Bool { !rows.contains { $0.identity.isBotManaged } }

    // MARK: - Remote bots (B4)

    /// Backing model for the roster's "Remote" group — reuses W9's
    /// `PeersViewModel` wholesale (registry read off `config.yaml`'s
    /// `bot_peers:`, plus the DM/async-run verbs over `hermes peer`) rather
    /// than re-parsing the registry or re-wrapping `HermesPeerCLI`. Its
    /// `peers`/`selectedPeerName`/`selectedPeer` are a SEPARATE identity
    /// space from `rows`/`selectedProfileName` — a peer registered under the
    /// same name as a local profile is a distinct row with its own selection
    /// state, never merged into or conflated with the local roster.
    /// Lazily constructed so a test (or a host with no peers configured)
    /// never spins up its transport. `@Observable` can't synthesize a
    /// `lazy var` (it rewrites stored properties into tracked accessors),
    /// so the laziness is hand-rolled with a backing optional.
    @ObservationIgnored private var _peers: PeersViewModel?
    var peers: PeersViewModel {
        if let existing = _peers { return existing }
        let vm = PeersViewModel(context: context)
        _peers = vm
        return vm
    }

    /// Gates the "Remote" roster group. Peer registration + `hermes peer`
    /// both ship at v0.21 (`hasPeerRunCommands` = `isV021OrLater`), so a
    /// host below that floor never shows the section even if `config.yaml`
    /// happens to carry a `bot_peers:` block from a newer host's export.
    var hasPeerRunCommands: Bool { capabilities.hasPeerRunCommands }

    // MARK: - Routines (B4)

    @ObservationIgnored private var routinesCache: [String: BotRoutinesViewModel] = [:]

    /// Memoized per bot, mirroring `conversation`'s reasoning: a
    /// `BotRoutinesViewModel` wraps a `CronViewModel` (loaded jobs, in-flight
    /// tasks), and rebuilding one on every SwiftUI body evaluation would
    /// discard that state and re-issue the cron load on every re-render.
    /// Never evicted on selection change (unlike `conversation`, which tears
    /// down a live subprocess) — a `CronViewModel` holds no process, so
    /// keeping every visited bot's routines cached just saves reloads.
    func routinesViewModel(for profileName: String) -> BotRoutinesViewModel {
        if let existing = routinesCache[profileName] { return existing }
        let vm = BotRoutinesViewModel(context: context, botName: profileName)
        routinesCache[profileName] = vm
        return vm
    }

    // MARK: - Agent configuration (Phase B P1)

    @ObservationIgnored private var agentCache: [String: BotAgentViewModel] = [:]

    /// Memoized per bot for the same reason routines are — and one more:
    /// the `SOUL.md` editor buffer lives in this view model and exists
    /// nowhere else until it is saved. Rebuilding the view model on a
    /// selection change (or a body evaluation) would silently throw away the
    /// user's unsaved identity prompt. Never evicted; it holds no process.
    func agentViewModel(for profileName: String) -> BotAgentViewModel {
        if let existing = agentCache[profileName] { return existing }
        let vm = BotAgentViewModel(
            context: context,
            profileName: profileName,
            capabilities: capabilities
        )
        agentCache[profileName] = vm
        return vm
    }

    /// The bot currently being edited, if its `SOUL.md` buffer is dirty. The
    /// roster's navigation guard asks this before switching selection —
    /// nothing else in Bots holds unsaved text.
    func unsavedAgentEdits(forProfile profileName: String?) -> Bool {
        guard let profileName, let vm = agentCache[profileName] else { return false }
        return vm.isSoulDirty
    }

    // MARK: - Conversation (B3)

    /// The live conversation, if any. **At most one exists at a time** — a
    /// bot conversation owns a `hermes acp` subprocess, and a per-bot cache
    /// would leave one running for every bot the user had ever clicked,
    /// none of which anything would ever reap: `AppCoordinator` caches this
    /// view model for the life of the window and has no teardown hook.
    private(set) var conversation: BotConversationViewModel?

    /// Test seam: build the conversation VM for a profile. Production makes
    /// a real one against the profile-pinned context.
    @ObservationIgnored
    var makeConversation: (ServerContext, String) -> BotConversationViewModel = { ctx, name in
        BotConversationViewModel(profileName: name, context: ctx)
    }

    /// Open (or reuse) the conversation for `profileName`. Idempotent for
    /// the bot already showing; opening a different bot closes the old one
    /// first.
    func openConversation(for profileName: String) {
        guard hasBotMode, BotsService.isAddressableProfile(profileName) else { return }
        if let existing = conversation, existing.profileName == profileName {
            existing.open()
            return
        }
        closeConversation()
        let vm = makeConversation(context, profileName)
        conversation = vm
        vm.open()
    }

    /// Stop and drop the live conversation. Call on bot switch, on leaving
    /// the section, and on window teardown.
    func closeConversation() {
        conversation?.close()
        conversation = nil
    }

    // MARK: - Loading

    func load(force: Bool = false) {
        guard hasBotMode else {
            rows = []
            hasLoaded = false
            return
        }
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        let backend = self.backend
        Task.detached(priority: .userInitiated) { [weak self] in
            let identities = backend.scan()
            // Avatar bytes are read here, off the main actor, and only for
            // profiles that actually have a file — `loadAvatar` returns nil
            // without a read otherwise, and refuses anything over 2MB before
            // it crosses the transport.
            var loaded: [BotRow] = []
            for identity in identities {
                let avatar = try? backend.loadAvatar(forProfile: identity.profileName)
                loaded.append(BotRow(identity: identity, avatar: avatar))
            }
            let rows = loaded
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.isLoading = false
                self.rows = rows
                // A selection that no longer exists (deleted, renamed) must
                // not linger and retarget the detail pane at nothing.
                if let selected = self.selectedProfileName,
                   !rows.contains(where: { $0.identity.profileName == selected }) {
                    self.selectedProfileName = nil
                }
                if self.selectedProfileName == nil {
                    self.selectedProfileName = self.bots.first?.identity.profileName
                }
            }
        }
    }

    // MARK: - Create

    /// Create a profile and then stamp its bot identity onto it.
    ///
    /// **Failure semantics.** These are two operations against two different
    /// mechanisms (`hermes profile create`, then a direct `profile.yaml`
    /// write — no CLI verb touches `ui_meta`), so a partial outcome is
    /// possible and is handled explicitly rather than hidden:
    ///
    /// 1. The CLI refuses → nothing was created; the CLI's stderr is shown.
    /// 2. The CLI succeeds and the identity write fails → the profile
    ///    **exists and is kept**. Deleting it to "clean up" would run an
    ///    irreversible `hermes profile delete` over a directory the user
    ///    asked for, to recover from what is usually a transient write
    ///    error. It reappears in the roster under "Other profiles" and the
    ///    message says so, so the retry is one click ("Make a Bot") and
    ///    never a silent half-made bot.
    func createBot(profileName: String, draft: BotDraft, cloneFrom: String?) {
        guard hasBotMode, !isWorking else { return }
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BotsService.isAddressableProfile(name), name != HermesProfileScope.defaultProfileName else {
            errorMessage = "Profile names must be lowercase letters, digits, dashes or underscores (max 64), and can't be \"default\"."
            return
        }
        var draft = draft
        draft.profileName = name

        isWorking = true
        errorMessage = nil
        let backend = self.backend
        let log = logger
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: CreateOutcome
            do {
                let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try backend.run(.create(
                    name: name,
                    cloneFrom: cloneFrom,
                    cloneAll: false,
                    noSkills: false,
                    description: description.isEmpty ? nil : description
                ))
                if result.exitCode != 0 {
                    outcome = .cliRefused(Self.cliFailureText(result))
                } else {
                    do {
                        var identity = backend.identity(forProfile: name)
                        draft.apply(to: &identity)
                        try backend.saveIdentity(identity)
                        outcome = .created
                    } catch {
                        outcome = .createdButUnmanaged(String(describing: error))
                    }
                }
            } catch {
                outcome = .cliRefused(String(describing: error))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                switch outcome {
                case .created:
                    self.selectedProfileName = name
                    self.flash("Created \(name)")
                case .createdButUnmanaged(let detail):
                    log.warning("bot identity write failed after create: \(detail, privacy: .public)")
                    self.selectedProfileName = name
                    self.errorMessage = "Profile \"\(name)\" was created, but its bot details couldn't be saved. It's listed under Other profiles — open it and choose Make a Bot to try again. (\(detail))"
                case .cliRefused(let detail):
                    log.warning("hermes profile create failed: \(detail, privacy: .public)")
                    self.errorMessage = detail
                }
                self.load(force: true)
            }
        }
    }

    private enum CreateOutcome: Sendable {
        case created
        case createdButUnmanaged(String)
        case cliRefused(String)
    }

    // MARK: - Save / promote / demote

    /// Persist an edit. Re-reads the profile immediately before writing so
    /// unknown keys, groups, `created`, and anything a concurrent Hermes
    /// Desktop edit added are the file's current values, not the sheet's.
    func save(_ draft: BotDraft) {
        guard hasBotMode, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let backend = self.backend
        let log = logger
        Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            do {
                var identity = backend.identity(forProfile: draft.profileName)
                draft.apply(to: &identity)
                try backend.saveIdentity(identity)
            } catch {
                failure = Self.saveFailureText(error, profileName: draft.profileName)
            }
            let result = failure
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if let result {
                    log.warning("bot save failed: \(result, privacy: .public)")
                    self.errorMessage = result
                } else {
                    self.flash("Saved \(draft.profileName)")
                }
                self.load(force: true)
            }
        }
    }

    /// Turn an unmanaged profile into a bot: the same write as an edit, from
    /// the profile's existing display name/description.
    func promote(_ row: BotRow) {
        var draft = BotDraft(identity: row.identity)
        if draft.title.isEmpty { draft.title = row.identity.profileName }
        save(draft)
    }

    /// Stop managing a profile as a bot: clear the `ui_meta['hermes-bots']`
    /// block so the profile drops back to "Other profiles". The profile
    /// directory, its sessions, its memories and its top-level
    /// `display_name`/`description` are untouched — only the bot-mode block
    /// Scarf/Hermes Desktop own goes away.
    ///
    /// This deliberately does NOT go through ``save(_:)``: `BotDraft.apply`
    /// stamps `isBotManaged = true` (saving through the editor is what MAKES
    /// a profile a bot), so routing demote through it produced a write that
    /// was byte-for-byte "Hide" — the affordance's own label over-promised
    /// (go/no-go blocking condition 2, A4-C2). `HermesBotProfileYAML.write`
    /// already implements the removal: an identity with `isBotManaged ==
    /// false` renders an empty block, which the writer splices out (along
    /// with a `ui_meta:` header left with no children), preserving every
    /// sibling namespace and unknown key exactly as the add/edit path does.
    func demote(_ row: BotRow) {
        guard hasBotMode, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let backend = self.backend
        let log = logger
        let name = row.identity.profileName
        Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            do {
                // Re-read first, same as `save`: unknown keys, groups and a
                // concurrent Hermes Desktop edit must be the file's current
                // values, not this row's snapshot.
                var identity = backend.identity(forProfile: name)
                identity.isBotManaged = false
                // Both live inside the block that is about to be removed;
                // clearing them keeps the in-memory identity honest for the
                // reload that follows.
                identity.pinned = nil
                identity.hidden = nil
                try backend.saveIdentity(identity)
            } catch {
                failure = Self.saveFailureText(error, profileName: name)
            }
            let result = failure
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if let result {
                    log.warning("bot demote failed: \(result, privacy: .public)")
                    self.errorMessage = result
                } else {
                    self.flash("Removed \(name) from Bots")
                }
                self.load(force: true)
            }
        }
    }

    /// Flip `pinned` from the roster's context menu without opening the editor.
    func togglePinned(_ row: BotRow) {
        var draft = BotDraft(identity: row.identity)
        draft.pinned.toggle()
        save(draft)
    }

    /// Flip `hidden` from the roster's context menu.
    func toggleHidden(_ row: BotRow) {
        var draft = BotDraft(identity: row.identity)
        draft.hidden.toggle()
        save(draft)
    }

    // MARK: - Avatar

    /// Store chosen image bytes and mark the identity as carrying a photo.
    /// The caller has already downscaled to fit ``HermesBotAvatar/maxBytes``.
    func setAvatar(_ data: Data, forProfile name: String) {
        guard hasBotMode, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        let backend = self.backend
        let log = logger
        Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            do {
                try backend.writeAvatar(data, forProfile: name)
                var identity = backend.identity(forProfile: name)
                identity.isBotManaged = true
                identity.imageKind = .photo
                identity.custom = true
                try backend.saveIdentity(identity)
            } catch {
                failure = Self.saveFailureText(error, profileName: name)
            }
            let result = failure
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if let result {
                    log.warning("avatar write failed: \(result, privacy: .public)")
                    self.errorMessage = result
                } else {
                    self.flash("Updated avatar for \(name)")
                }
                self.load(force: true)
            }
        }
    }

    // MARK: - Rename / delete

    /// Rename through the CLI — `hermes profile rename` moves the directory
    /// and rewrites the alias, which no file write of Scarf's could do.
    func rename(_ row: BotRow, to newName: String) {
        guard hasBotMode, !isWorking else { return }
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HermesProfileScope.isValidName(target) else {
            errorMessage = "Profile names must be lowercase letters, digits, dashes or underscores (max 64)."
            return
        }
        runLifecycle(.rename(from: row.identity.profileName, to: target), success: "Renamed to \(target)") { [weak self] in
            self?.selectedProfileName = target
        }
    }

    /// **Destructive.** `hermes profile delete` removes the whole profile
    /// directory — sessions, memories, state.db, `.env`. The confirmation is
    /// entirely the UI's job (B0's `isDestructive` marks it), and this method
    /// is only ever called from behind one.
    func delete(_ row: BotRow) {
        guard hasBotMode, !isWorking else { return }
        let name = row.identity.profileName
        runLifecycle(.delete(name: name), success: "Deleted \(name)") { [weak self] in
            self?.selectedProfileName = nil
        }
    }

    private func runLifecycle(
        _ action: BotsService.Lifecycle,
        success: String,
        then onSuccess: @escaping @MainActor () -> Void
    ) {
        isWorking = true
        errorMessage = nil
        let backend = self.backend
        let log = logger
        Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            do {
                let result = try backend.run(action)
                if result.exitCode != 0 { failure = Self.cliFailureText(result) }
            } catch {
                failure = String(describing: error)
            }
            let result = failure
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if let result {
                    log.warning("hermes profile action failed: \(result, privacy: .public)")
                    self.errorMessage = result
                } else {
                    onSuccess()
                    self.flash(success)
                }
                self.load(force: true)
            }
        }
    }

    // MARK: - Failure text

    /// The CLI's own words, preferring stderr and falling back to stdout —
    /// Hermes' profile errors ("profile 'x' already exists", "cannot delete
    /// the active profile") are the actionable text.
    nonisolated static func cliFailureText(_ result: ProcessResult) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "hermes profile exited with code \(result.exitCode)."
    }

    /// Human wording for the write failures B0 can raise. `unsafeToWrite` in
    /// particular is not a transient error — it means the file is in a shape
    /// the surgical writer refuses to guess at, and the honest advice is to
    /// go look at it.
    nonisolated static func saveFailureText(_ error: Error, profileName: String) -> String {
        switch error {
        case BotsError.unsupported:
            return "This Hermes is older than v0.20.3, which is where Bot Mode's profile metadata was introduced. Saving would write a key it ignores."
        case BotsError.profileMissing(let name):
            return "No profile directory for \"\(name)\" on this host."
        case BotsError.unsafeToWrite(let path):
            return "Scarf won't edit \(path) — it has a shape (duplicate ui_meta, an inline mapping, or an oversized block) the writer refuses to guess at. Edit it by hand, then reload."
        case BotsError.avatarTooLarge(_, let size):
            return "That image is \(size) bytes after conversion; Hermes caps avatars at \(HermesBotAvatar.maxBytes)."
        default:
            return "Couldn't save \(profileName): \(String(describing: error))"
        }
    }

    private func flash(_ text: String) {
        message = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.message == text else { return }
            self.message = nil
        }
    }
}
