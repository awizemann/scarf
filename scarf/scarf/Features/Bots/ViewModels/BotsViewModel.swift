import Foundation
import SwiftUI
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
    /// Every profile plus its avatar's *stat* — one round trip where the
    /// transport supports it. What the roster paints from (Phase B P2).
    func scanRoster() async -> [BotRosterEntry]
    /// One profile's identity, re-read from disk.
    func identity(forProfile name: String) -> HermesBotIdentity
    /// Avatar bytes, or nil when the profile has none.
    func loadAvatar(forProfile name: String) throws -> HermesBotAvatar?
    /// Avatar bytes behind a stat the roster scan already produced — no
    /// extension re-probe, and only ever called on a cache miss.
    func loadAvatar(at stat: BotAvatarStat) throws -> HermesBotAvatar
    /// The bot's Bot Chat activity from ITS OWN profile database, or nil when
    /// there is no Bot Chat (or no readable database).
    func activity(forProfile name: String) async -> BotActivity?
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
    let context: ServerContext

    private var service: BotsService {
        BotsService(
            transport: transport,
            paths: paths,
            capabilities: capabilities,
            // Only a remote host pays per-file round trips; see
            // `BotsService.init(…prefersBatchedScan:)`.
            prefersBatchedScan: context.isRemote
        )
    }

    init(context: ServerContext, capabilities: HermesCapabilities) {
        self.transport = context.makeTransport()
        self.paths = context.paths
        self.capabilities = capabilities
        self.context = context
    }

    func scan() -> [HermesBotIdentity] { service.scan() }
    func scanRoster() async -> [BotRosterEntry] { await service.rosterEntries() }
    func loadAvatar(at stat: BotAvatarStat) throws -> HermesBotAvatar { try service.loadAvatar(at: stat) }

    /// Open the BOT's own `state.db` — never the window's. Each profile
    /// carries its own database, migrated independently, so `open()` runs per
    /// profile and the schema flags it caches are that database's.
    func activity(forProfile name: String) async -> BotActivity? {
        guard BotsService.isAddressableProfile(name) else { return nil }
        let service = HermesDataService(context: context.pinnedToProfile(name))
        guard await service.open() else {
            await service.close()
            return nil
        }
        let activity = await service.fetchBotChatActivity()
        await service.close()
        return activity
    }

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
    /// Where the avatar is and what it looked like at scan time — the cache
    /// key. Present as soon as the roster scan lands, i.e. before the bytes:
    /// the row paints the generated fallback first and swaps in the photo when
    /// it arrives (charter C10 — nothing heavy on first paint).
    var avatarStat: BotAvatarStat? = nil
    /// The bot's Bot Chat activity, filled in asynchronously after paint.
    var activity: BotActivity? = nil
    /// Set when the async avatar fill hit `BotsError.avatarTooLarge` for this
    /// profile — a real file exists but Scarf refused to read it (over the
    /// same size floor `BotsService.loadAvatar` enforces on the save path).
    /// Surfaced on the row as a small warning rather than swallowed, so the
    /// generated fallback doesn't quietly masquerade as "no avatar set"
    /// (audit A1-L9).
    var avatarTooLarge = false

    var id: String { identity.profileName }
    /// The key this row's avatar is cached under, or nil when it has none.
    var avatarCacheKey: BotAvatarCache.Key? {
        avatarStat.map { BotAvatarCache.Key(profileName: identity.profileName, stat: $0) }
    }
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
        backend: (any BotsBackend)? = nil,
        peers: PeersViewModel? = nil
    ) {
        self.context = context
        self.capabilities = capabilities
        self.injectedBackend = backend
        self.backend = backend ?? LiveBotsBackend(context: context, capabilities: capabilities)
        self._peers = peers
    }

    // MARK: - State

    private(set) var rows: [BotRow] = [] { didSet { recomputeRoster() } }
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

    /// Roster filter text. Applies to every group (bots, hidden, other
    /// profiles) — a search that silently skipped a collapsed group would
    /// report "no results" for a profile that is right there.
    /// **Never touches the selection.** Filtering a bot out of view leaves the
    /// detail pane on it, deliberately: `selectedProfileName`'s `didSet` tears
    /// down the live `hermes acp` subprocess, so retargeting the selection
    /// from here would kill and respawn a conversation on individual
    /// keystrokes — and it would do so *behind* `BotsView.requestSelection`,
    /// the single choke point that holds a switch when the bot being left has
    /// unsaved `SOUL.md` edits (P1). A filter is a view of the roster, not a
    /// navigation.
    var searchText = "" { didSet { recomputeRoster() } }

    /// Roster ordering. Not persisted by this type — the view mirrors it from
    /// `@AppStorage`, the same shape `ChatSessionListPane` uses for its own
    /// list preference (there is no `@SceneStorage` precedent in Scarf, so
    /// this is app-wide rather than per-window; documented, not accidental).
    var sortOrder: BotRosterSort = .pinnedThenName { didSet { recomputeRoster() } }

    /// How the roster is ordered.
    enum BotRosterSort: String, CaseIterable, Sendable {
        /// The original order: pinned bots first, then by title.
        case pinnedThenName
        /// Most recently active Bot Chat first. Pins are NOT hoisted here —
        /// the whole point of the mode is "who moved last", and a pinned but
        /// silent bot sitting above a bot that just replied would defeat it.
        /// Bots with no activity (no Bot Chat, or none read yet) sort last.
        case recentActivity

        /// `LocalizedStringResource`, not `String` — the picker bound `Text`'s
        /// verbatim overload and neither option was ever extractable.
        var label: LocalizedStringResource {
            switch self {
            case .pinnedThenName: return "Pinned, then name"
            case .recentActivity: return "Recent activity"
            }
        }
    }

    @ObservationIgnored private var hasLoaded = false

    /// Guards against an older in-flight scan clobbering a newer one's
    /// result. Every mutating action ends in `load(force: true)`, so two
    /// scans overlapping is the normal case, not the exotic one — and a
    /// slow pre-delete scan landing after a fast post-delete scan would put
    /// the deleted bot back on screen. Same generation counter
    /// `HermesCapabilitiesStore` uses for the same reason.
    @ObservationIgnored private var loadGeneration = 0

    // MARK: - Derived roster

    // The five roster projections below are MEMOIZED, not computed.
    //
    // As computed properties each one re-ran a filter whose predicate is
    // `String.range(of:options:[.caseInsensitive, .diacriticInsensitive])` —
    // an ICU collation search, not a byte compare — over every profile, plus
    // a sort; `visibleRows` re-ran all three; and `searchFoundNothing` re-ran
    // `visibleRows`. A single body evaluation of `BotsView` touches all of
    // them, and the filter field bound to `searchText` invalidates that body
    // on every keystroke. Their three inputs (`rows`, `searchText`,
    // `sortOrder`) each recompute the set on `didSet`, so the memo cannot go
    // stale without a fourth input appearing — which the compiler would show
    // as an unread property here.

    /// Bot-managed, not hidden, matching the filter, in the chosen order.
    private(set) var bots: [BotRow] = []

    /// Bot-managed but flagged `hidden` — collapsed behind a disclosure
    /// rather than dropped: Scarf can un-hide them, so hiding them
    /// irrecoverably would be a one-way door.
    private(set) var hiddenBots: [BotRow] = []

    /// Profiles with no `hermes-bots` block. Kept in scan order (`default`
    /// first, then sorted ids) — these are candidates to promote, not a
    /// roster to rank. Filtered, never re-sorted.
    private(set) var otherProfiles: [BotRow] = []

    /// Every row the roster is currently showing, in display order.
    private(set) var visibleRows: [BotRow] = []

    /// True when a filter is on and it matched nothing anywhere.
    private(set) var searchFoundNothing: Bool = false

    private func recomputeRoster() {
        // ONE filter pass over `rows`, whose per-row cost is the expensive
        // part, then bucket — rather than three passes that each re-test
        // every row.
        var managedVisible: [BotRow] = []
        var managedHidden: [BotRow] = []
        var unmanaged: [BotRow] = []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        for row in rows {
            if !query.isEmpty, !Self.matches(row.identity, query: query) { continue }
            if !row.identity.isBotManaged {
                unmanaged.append(row)
            } else if row.isHidden {
                managedHidden.append(row)
            } else {
                managedVisible.append(row)
            }
        }
        bots = sorted(managedVisible)
        hiddenBots = sorted(managedHidden)
        otherProfiles = unmanaged
        visibleRows = bots + hiddenBots + otherProfiles
        searchFoundNothing = !query.isEmpty && visibleRows.isEmpty
    }

    /// Does this identity match the roster filter?
    ///
    /// Case- AND diacritic-insensitive, against the three things a user would
    /// type: the title they see, the blurb under it, and the profile id the
    /// row shows (which is what `hermes -p` takes, so it is the name people
    /// who live in the CLI actually remember). Substring, not prefix — a bot
    /// called "Deploy Bot" has to be findable by "bot".
    nonisolated static func matches(_ identity: HermesBotIdentity, query: String) -> Bool {
        let haystacks = [
            identity.resolvedTitle,
            identity.resolvedDescription,
            identity.profileName
        ]
        return haystacks.contains { field in
            field.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: .current
            ) != nil
        }
    }

    private func sorted(_ input: [BotRow]) -> [BotRow] {
        switch sortOrder {
        case .pinnedThenName: return Self.sortBots(input)
        case .recentActivity: return Self.sortBotsByActivity(input)
        }
    }

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

    /// Most recent Bot Chat first; no-activity rows last.
    ///
    /// **Ties fall through to `sortBots`**, which is total. That matters more
    /// than it looks: until the async activity pass lands, *every* row has
    /// `nil` activity, so a roster sorted by activity is initially one giant
    /// tie — and without a total tie-break it would reshuffle on every fill-in
    /// and every re-render. Two bots with the same timestamp (a routine that
    /// fanned out to several bots at once) are the same case.
    static func sortBotsByActivity(_ input: [BotRow]) -> [BotRow] {
        let fallback = sortBots(input)
        let rank = Dictionary(uniqueKeysWithValues: fallback.enumerated().map { ($0.element.id, $0.offset) })
        return fallback.sorted { lhs, rhs in
            let l = lhs.activity?.lastMessageAt
            let r = rhs.activity?.lastMessageAt
            switch (l, r) {
            case (nil, nil): break
            case (_?, nil): return true
            case (nil, _?): return false
            case (let l?, let r?):
                if l != r { return l > r }
            }
            return (rank[lhs.id] ?? 0) < (rank[rhs.id] ?? 0)
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
    ///
    /// Production callers inject the coordinator-cached instance
    /// (`AppCoordinator.featureViewModel(for: .peers, …)`, the same one
    /// `ContentView` hands the standalone Peers section) via `init(peers:)`
    /// — a peer async-run started from Bots▸Remote must stay visible and
    /// stoppable from the Peers pane, and vice versa (queued audit-board
    /// item A2-F5). Only a test (or a build that somehow reaches this
    /// accessor before injection) falls back to constructing its own.
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

    // MARK: - Presence (Phase B P2)

    /// Whether this bot's ACP conversation is open in THIS window, and whether
    /// it is mid-reply. Purely a projection of `conversation` — see
    /// ``BotPresence``. At most one row is ever non-`offline`, because
    /// `openConversation` enforces one live subprocess.
    func presence(forProfile name: String) -> BotPresence {
        guard let conversation, conversation.profileName == name else { return .offline }
        var isFailed = false
        var isResolving = false
        switch conversation.phase {
        case .failed: isFailed = true
        case .resolving, .creating: isResolving = true
        case .idle, .noConversationYet, .live: break
        }
        return BotPresence.resolve(
            isCurrentConversation: true,
            isResolving: isResolving,
            isFailed: isFailed,
            isConnected: conversation.chat.isACPConnected,
            isAgentWorking: conversation.chat.richChatViewModel.isAgentWorking
        )
    }

    // MARK: - Avatar cache (Phase B P2 / audit A1-M4)

    /// Per-connection, never static: avatar paths are absolute and collide
    /// across hosts. See ``BotAvatarCache``.
    @ObservationIgnored let avatarCache = BotAvatarCache()

    /// The decoded photo for a row, or nil to render the generated fallback.
    /// Decodes at most once per (profile, path, size, mtime).
    func avatarImage(for row: BotRow) -> Image? {
        guard let key = row.avatarCacheKey else { return nil }
        return avatarCache.image(for: key)
    }

    // MARK: - Loading

    /// Load the roster.
    ///
    /// Three phases, deliberately separated (charter C10 — nothing heavy on
    /// first paint, and the acceptance bar is an instant roster on a
    /// 12-profile SSH host):
    ///
    /// 1. **Identities.** One batched round trip on a remote host
    ///    (`BotsService.rosterEntries()`), carrying each avatar's stat but not
    ///    its bytes. Published immediately — this is what paints.
    /// 2. **Avatar bytes**, per profile, only on a cache miss. A metadata save
    ///    ends in a reload whose stats are unchanged, so every key hits and
    ///    nothing crosses the transport (the "metadata-only saves must not
    ///    re-read avatar bytes" requirement is a *consequence* of the key, not
    ///    a special case in the save path).
    /// 3. **Activity + previews**, per bot, each against that bot's own
    ///    `state.db`. The most expensive phase by far — N database opens — so
    ///    it runs last, only for bot-managed profiles, and only when
    ///    `refreshActivity` is set: a pin toggle must not re-open twelve
    ///    databases.
    ///
    /// Every phase re-checks `loadGeneration` before publishing, so a scan the
    /// user has already superseded can't land avatars or previews on top of a
    /// newer roster.
    func load(force: Bool = false, refreshActivity: Bool = false) {
        guard hasBotMode else {
            rows = []
            hasLoaded = false
            return
        }
        if !force, hasLoaded || isLoading { return }
        let isFirstLoad = !hasLoaded
        hasLoaded = true
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        let backend = self.backend
        let wantsActivity = refreshActivity || isFirstLoad
        Task { [weak self] in
            let entries = await backend.scanRoster()
            guard let self, generation == self.loadGeneration else { return }
            self.publish(entries, generation: generation)
            await self.fillAvatars(entries, generation: generation, backend: backend)
            guard wantsActivity else { return }
            await self.fillActivity(generation: generation, backend: backend)
        }
    }

    /// Phase 1 — paint. Rows carry whatever bytes the cache already holds, so
    /// a re-scan of an unchanged avatar shows the photo with no flicker back
    /// to the generated fallback.
    private func publish(_ entries: [BotRosterEntry], generation: Int) {
        guard generation == loadGeneration else { return }
        isLoading = false
        rows = entries.map { entry in
            let stat = entry.avatar
            let cached = stat.map { BotAvatarCache.Key(profileName: entry.identity.profileName, stat: $0) }
                .flatMap { avatarCache.avatar(for: $0) }
            return BotRow(
                identity: entry.identity,
                avatar: cached,
                avatarStat: stat,
                // Activity survives a re-scan: it is about the bot's chat, not
                // about `profile.yaml`, and dropping it would blank every
                // preview on a pin toggle.
                activity: activityCache[entry.identity.profileName]
            )
        }
        // A selection that no longer exists (deleted, renamed) must not linger
        // and retarget the detail pane at nothing.
        if let selected = selectedProfileName,
           !rows.contains(where: { $0.identity.profileName == selected }) {
            selectedProfileName = nil
        }
        if selectedProfileName == nil {
            // Deliberately the unfiltered roster, not `bots` (which is
            // narrowed by `searchText`): autoselecting the first *search
            // match* would mean typing into the roster filter with nothing
            // selected silently picks whatever the query happens to match,
            // rather than the same default bot regardless of what's typed.
            selectedProfileName = sorted(rows.filter { $0.identity.isBotManaged && !$0.isHidden })
                .first?.identity.profileName
        }
    }

    /// Phase 2 — avatar bytes, one profile at a time, off the main actor.
    ///
    /// Sequential on purpose: over SSH these are N reads on one ControlMaster
    /// channel, and firing them concurrently would contend for it while
    /// starving the (more important) activity pass behind them.
    private func fillAvatars(
        _ entries: [BotRosterEntry],
        generation: Int,
        backend: any BotsBackend
    ) async {
        for entry in entries {
            guard generation == loadGeneration else { return }
            guard let stat = entry.avatar else { continue }
            let key = BotAvatarCache.Key(profileName: entry.identity.profileName, stat: stat)
            if avatarCache.avatar(for: key) != nil { continue }
            let outcome = await Task.detached(priority: .utility) { () -> Result<HermesBotAvatar, Error> in
                Result { try backend.loadAvatar(at: stat) }
            }.value
            guard generation == loadGeneration else { continue }
            switch outcome {
            case .success(let avatar):
                avatarCache.store(avatar, for: key)
                if let index = rows.firstIndex(where: { $0.id == entry.identity.profileName }) {
                    rows[index].avatar = avatar
                    rows[index].avatarTooLarge = false
                }
            case .failure(BotsError.avatarTooLarge(_, _)):
                if let index = rows.firstIndex(where: { $0.id == entry.identity.profileName }) {
                    rows[index].avatarTooLarge = true
                }
            case .failure:
                // Anything else (transient transport hiccup, missing file
                // between stat and read) — the generated fallback is the
                // right degrade, same as before this fixup. But clear a
                // stale `avatarTooLarge` triangle from an earlier stat: this
                // failure means something else entirely, and leaving the old
                // warning up would misreport why the avatar isn't showing.
                if let index = rows.firstIndex(where: { $0.id == entry.identity.profileName }) {
                    rows[index].avatarTooLarge = false
                }
                continue
            }
        }
    }

    /// Phase 3 — activity + previews, per bot, against each bot's own
    /// `state.db`.
    ///
    /// **This is the expensive one, and it is priced honestly.** Per bot on a
    /// remote host: one preflight round trip (`RemoteSQLiteBackend.open`
    /// batches sqlite3's version and both `PRAGMA table_info`s into one
    /// script), then the title lookup, the compression-tip walk, the
    /// last-message read and the preview — call it six or seven round trips,
    /// so roughly half a second per bot at typical SSH latency. Twelve bots is
    /// therefore seconds, which is exactly why it runs after paint, only for
    /// bot-managed profiles, only on a first load or an explicit reload, and
    /// sequentially rather than fanning twelve concurrent sqlite3 invocations
    /// at one ControlMaster channel. Each database must be opened separately
    /// regardless: profiles migrate independently, so the schema flags are
    /// per-database and cannot be probed once for the host.
    private func fillActivity(generation: Int, backend: any BotsBackend) async {
        let names = rows.filter { $0.identity.isBotManaged }.map(\.id)
        for name in names {
            guard generation == loadGeneration else { return }
            let activity = await backend.activity(forProfile: name)
            guard generation == loadGeneration else { return }
            // A bot with no Bot Chat yet keeps no entry — nil is a real
            // answer ("nothing to show"), not a failure to record, and
            // caching it would only make the next reload skip a chat the
            // user has since started.
            guard let activity else { continue }
            activityCache[name] = activity
            if let index = rows.firstIndex(where: { $0.id == name }) {
                rows[index].activity = activity
            }
        }
    }

    /// Activity by profile, kept across re-scans (see ``publish(_:generation:)``).
    @ObservationIgnored private var activityCache: [String: BotActivity] = [:]

    /// Leaving the Bots section: drop the filter so returning shows the whole
    /// roster. A filter that survived would look like a roster that had lost
    /// its bots.
    func clearSearch() {
        searchText = ""
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
                    self.flash(String(localized: "Saved \(draft.profileName)"))
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
                // Invalidate on BOTH outcomes. A remote `stat` reports mtime
                // in whole seconds, so a second write inside the same second
                // with the same byte count would reuse the previous key and
                // render the OLD picture; and a failed write may still have
                // landed the bytes before failing on the identity save. The
                // (path, size, mtime) key is the fast path, not the
                // correctness argument.
                self.avatarCache.invalidate(profileName: name)
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
        let from = row.identity.profileName
        // Same unsaved-edits floor `BotsView.requestSelection` enforces for a
        // roster switch: `agentCache` is keyed by profile name, so a rename
        // would otherwise leave a dirty SOUL.md buffer cached under a name
        // nothing addresses any more — `unsavedAgentEdits` (which reads that
        // very cache) would go blind to it from that point on.
        guard !unsavedAgentEdits(forProfile: from) else {
            errorMessage = "\(from) has unsaved SOUL.md changes. Save or discard them before renaming."
            return
        }
        runLifecycle(.rename(from: from, to: target), success: "Renamed to \(target)") { [weak self] in
            guard let self else { return }
            // The directory moved, so every cached avatar path under the old
            // name is dead. Keys carry the profile name, so nothing would be
            // mis-served — this just stops a window accumulating them.
            self.avatarCache.invalidate(profileName: from)
            self.activityCache[from] = nil
            // Invalidate rather than re-key: both cached view models capture
            // their profile name in an immutable `let` used on every backend
            // call, so moving the existing instance to the new dictionary
            // key would leave it silently addressing the now-renamed-away
            // profile directory. Dropping them lets the next
            // `agentViewModel(for:)`/`routinesViewModel(for:)` build a fresh
            // instance under the new name instead. Safe to drop here
            // specifically because the guard above already confirmed there
            // is no unsaved SOUL.md buffer to lose.
            self.agentCache[from] = nil
            self.routinesCache[from] = nil
            self.selectedProfileName = target
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
            self?.avatarCache.invalidate(profileName: name)
            self?.activityCache[name] = nil
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
            // Curly apostrophe (Apple style) — deliberately the SAME
            // catalog key as `SettingsViewModel`'s save-failure message.
            // A straight `'` here forked the catalog into two entries
            // differing only by the apostrophe glyph, each carrying its
            // own six translations.
            return String(localized: "Couldn’t save \(profileName): \(String(describing: error))")
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
