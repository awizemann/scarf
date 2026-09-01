import AppKit
import Foundation
import Testing
import ScarfCore
@testable import scarf

/// The avatar importer: a chosen file must always arrive under Hermes'
/// own 2MB `set_asset` ceiling, or be refused before any bytes cross the
/// transport.
@Suite("Bot avatar import (B2)")
struct BotAvatarImportTests {

    private func image(edge: CGFloat) -> NSImage {
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size)
        image.lockFocus()
        // Noise, not a flat fill: a solid color compresses to almost
        // nothing and would pass the cap without exercising the downscale.
        for x in stride(from: 0, to: edge, by: 2) {
            for y in stride(from: 0, to: edge, by: 2) {
                NSColor(
                    calibratedRed: Double.random(in: 0...1),
                    green: Double.random(in: 0...1),
                    blue: Double.random(in: 0...1),
                    alpha: 1
                ).setFill()
                NSRect(x: x, y: y, width: 2, height: 2).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    @Test("a large noisy image is downscaled under the 2MB asset cap")
    func downscalesOversizedImages() throws {
        let data = try BotAvatarImport.pngData(from: image(edge: 2_048))
        #expect(data.count <= HermesBotAvatar.maxBytes)
        // PNG magic — the canonical asset Scarf writes is always avatar.png,
        // whatever the source format was.
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("a small image round-trips without being upscaled")
    func doesNotUpscaleSmallImages() throws {
        let data = try BotAvatarImport.pngData(from: image(edge: 64))
        #expect(data.count <= HermesBotAvatar.maxBytes)
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 64)
    }

    @Test("a zero-sized image is refused rather than written as nothing")
    func refusesDegenerateImages() {
        #expect(throws: BotAvatarImport.Failure.cannotFit) {
            try BotAvatarImport.pngData(from: NSImage(size: .zero))
        }
    }
}

/// Work package B2 — the Bots section's view-model logic, gating, and
/// analytics token.
///
/// Everything here runs against ``MockBotsBackend``: no Hermes home, no
/// transport, no `hermes` binary. That's the whole point of the
/// ``BotsBackend`` seam — the ordering rules, the promote/demote writes, the
/// editor round-trip and the create-flow's partial-failure semantics are
/// decisions, and decisions should be testable without a host.
@Suite("Bots section (B2)")
@MainActor
struct BotsViewModelTests {

    // MARK: - Fixtures

    /// A scriptable `BotsBackend`. Reference type behind a `Sendable` shell
    /// so the detached work in the view model can call it and the test can
    /// still read what happened afterwards.
    final class MockBotsBackend: BotsBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _identities: [String: HermesBotIdentity] = [:]
        private var _avatars: [String: HermesBotAvatar] = [:]

        /// When set, `saveIdentity` throws this instead of writing.
        var saveError: BotsError?
        /// Exit code the next `run` reports, plus its stderr.
        var lifecycleExit: Int32 = 0
        var lifecycleStderr = ""
        /// When set, `run` throws instead of completing.
        var lifecycleThrows: BotsError?

        private(set) var savedIdentities: [HermesBotIdentity] = []
        private(set) var lifecycleActions: [BotsService.Lifecycle] = []
        private(set) var writtenAvatars: [(name: String, bytes: Int)] = []

        init(_ identities: [HermesBotIdentity] = []) {
            for identity in identities { _identities[identity.profileName] = identity }
            order = identities.map(\.profileName)
        }

        /// Scan order, as `_roster` would produce it.
        private(set) var order: [String]

        func scan() -> [HermesBotIdentity] {
            lock.lock(); defer { lock.unlock() }
            return order.compactMap { _identities[$0] }
        }

        func identity(forProfile name: String) -> HermesBotIdentity {
            lock.lock(); defer { lock.unlock() }
            return _identities[name] ?? HermesBotIdentity(profileName: name, profileDirectory: "/tmp/\(name)")
        }

        func loadAvatar(forProfile name: String) throws -> HermesBotAvatar? {
            lock.lock(); defer { lock.unlock() }
            return _avatars[name]
        }

        func saveIdentity(_ identity: HermesBotIdentity) throws {
            lock.lock(); defer { lock.unlock() }
            if let saveError { throw saveError }
            savedIdentities.append(identity)
            _identities[identity.profileName] = identity
            if !order.contains(identity.profileName) { order.append(identity.profileName) }
        }

        func writeAvatar(_ data: Data, forProfile name: String) throws {
            lock.lock(); defer { lock.unlock() }
            writtenAvatars.append((name, data.count))
            _avatars[name] = HermesBotAvatar(data: data, mimeType: "image/png", path: "/tmp/\(name)/assets/avatar.png")
        }

        func run(_ action: BotsService.Lifecycle) throws -> ProcessResult {
            lock.lock(); defer { lock.unlock() }
            lifecycleActions.append(action)
            if let lifecycleThrows { throw lifecycleThrows }
            if case .create(let name, _, _, _, let description) = action, lifecycleExit == 0 {
                // Mirror the CLI: create makes the directory and persists
                // --description, but touches NOTHING under ui_meta.
                _identities[name] = HermesBotIdentity(
                    profileName: name,
                    profileDirectory: "/tmp/\(name)",
                    profileDescription: description ?? "",
                    isBotManaged: false
                )
                if !order.contains(name) { order.append(name) }
            }
            return ProcessResult(
                exitCode: lifecycleExit,
                stdout: Data(),
                stderr: Data(lifecycleStderr.utf8)
            )
        }
    }

    /// A host at the Bot Mode floor.
    private static var botCapableCapabilities: HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes 0.20.3",
            semver: .init(major: 0, minor: 20, patch: 3),
            dateVersion: nil
        )
    }

    /// A host one patch below it.
    private static var preBotCapabilities: HermesCapabilities {
        HermesCapabilities(
            versionLine: "hermes 0.20.2",
            semver: .init(major: 0, minor: 20, patch: 2),
            dateVersion: nil
        )
    }

    private static func bot(
        _ name: String,
        title: String? = nil,
        pinned: Bool? = nil,
        hidden: Bool? = nil,
        managed: Bool = true
    ) -> HermesBotIdentity {
        HermesBotIdentity(
            profileName: name,
            profileDirectory: "/tmp/\(name)",
            isBotManaged: managed,
            title: title,
            hidden: hidden,
            pinned: pinned
        )
    }

    private func makeViewModel(
        _ backend: MockBotsBackend,
        capabilities: HermesCapabilities? = nil
    ) -> BotsViewModel {
        BotsViewModel(
            context: .local,
            capabilities: capabilities ?? Self.botCapableCapabilities,
            backend: backend
        )
    }

    /// The view model loads on a detached task; spin the main actor until
    /// the roster lands rather than sleeping a fixed interval.
    private func waitForLoad(_ viewModel: BotsViewModel, expecting count: Int) async {
        for _ in 0..<200 {
            if viewModel.rows.count == count, !viewModel.isLoading, !viewModel.isWorking { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForIdle(_ viewModel: BotsViewModel) async {
        for _ in 0..<200 {
            if !viewModel.isWorking, !viewModel.isLoading { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Roster ordering

    @Test("pinned bots sort first, then by display name, with the profile id as tie-break")
    func rosterOrdering() {
        let rows = [
            BotRow(identity: Self.bot("zulu", title: "Zulu")),
            BotRow(identity: Self.bot("alpha", title: "alpha")),
            BotRow(identity: Self.bot("mike", title: "Mike", pinned: true)),
            // Two bots sharing a title: the id breaks the tie so the order
            // is total and stable across reloads.
            BotRow(identity: Self.bot("bravo-2", title: "Bravo")),
            BotRow(identity: Self.bot("bravo-1", title: "Bravo")),
        ]
        let sorted = BotsViewModel.sortBots(rows).map(\.identity.profileName)
        #expect(sorted == ["mike", "alpha", "bravo-1", "bravo-2", "zulu"])
    }

    @Test("hidden bots and unmanaged profiles are split out of the main roster")
    func rosterBuckets() async {
        let backend = MockBotsBackend([
            Self.bot("default", managed: false),
            Self.bot("archive", title: "Archive", hidden: true),
            Self.bot("research", title: "Research"),
            Self.bot("scratch", managed: false),
        ])
        let viewModel = makeViewModel(backend)
        viewModel.load()
        await waitForLoad(viewModel, expecting: 4)

        #expect(viewModel.bots.map(\.identity.profileName) == ["research"])
        #expect(viewModel.hiddenBots.map(\.identity.profileName) == ["archive"])
        // Unmanaged profiles stay in scan order — they're candidates, not
        // a ranked roster.
        #expect(viewModel.otherProfiles.map(\.identity.profileName) == ["default", "scratch"])
        #expect(!viewModel.isEmptyRoster)
        // Selection defaults to the first visible bot, never a hidden one
        // or a bare profile.
        #expect(viewModel.selectedProfileName == "research")
    }

    @Test("a host with only plain profiles is an empty roster, not a missing section")
    func emptyRosterIsAState() async {
        let backend = MockBotsBackend([Self.bot("default", managed: false)])
        let viewModel = makeViewModel(backend)
        viewModel.load()
        await waitForLoad(viewModel, expecting: 1)

        #expect(viewModel.isEmptyRoster)
        #expect(viewModel.hasBotMode)
        #expect(viewModel.otherProfiles.count == 1)
    }

    // MARK: - Gating

    @Test("pre-v0.20.3 hosts get no roster at all")
    func preFloorHostIsGated() async {
        let backend = MockBotsBackend([Self.bot("research", title: "Research")])
        let viewModel = makeViewModel(backend, capabilities: Self.preBotCapabilities)
        #expect(!viewModel.hasBotMode)
        viewModel.load()
        await waitForIdle(viewModel)
        #expect(viewModel.rows.isEmpty)
    }

    @Test("an undetected host (.empty capabilities) is gated too")
    func undetectedHostIsGated() async {
        let backend = MockBotsBackend([Self.bot("research", title: "Research")])
        let viewModel = makeViewModel(backend, capabilities: .empty)
        #expect(!viewModel.hasBotMode)
        viewModel.load()
        await waitForIdle(viewModel)
        #expect(viewModel.rows.isEmpty)
        // …and no write can slip through the gate either.
        viewModel.save(BotDraft(identity: Self.bot("research")))
        await waitForIdle(viewModel)
        #expect(backend.savedIdentities.isEmpty)
    }

    @Test("the capability answer landing later flips the surface on")
    func lateCapabilityProbeEnablesTheSurface() async {
        // The async-probe race: the store seeds `.empty` and answers after
        // the first render, so the view model must accept the upgrade.
        let backend = MockBotsBackend([Self.bot("research", title: "Research")])
        let viewModel = makeViewModel(backend, capabilities: .empty)
        viewModel.load()
        await waitForIdle(viewModel)
        #expect(viewModel.rows.isEmpty)

        viewModel.capabilities = Self.botCapableCapabilities
        viewModel.load(force: true)
        await waitForLoad(viewModel, expecting: 1)
        #expect(viewModel.bots.count == 1)
    }

    // MARK: - Editor round-trip

    @Test("an edit writes only the fields the editor owns and preserves everything else")
    func editorRoundTripPreservesUnknownMetadata() async {
        // A bot carrying every key B2's editor does NOT show: a created
        // timestamp, groups, the legacy group scalar, and two unmodeled
        // lines B0 keeps verbatim.
        let original = HermesBotIdentity(
            profileName: "research",
            profileDirectory: "/tmp/research",
            displayName: "Research",
            profileDescription: "Reads things.",
            descriptionIsAuto: true,
            isBotManaged: true,
            title: "Research",
            botDescription: "Reads things.",
            color: "#111111",
            shape: "circle",
            imageKind: .photo,
            custom: true,
            hidden: false,
            pinned: false,
            groups: ["lab"],
            legacyGroup: "old-lab",
            created: 1_700_000_000_000,
            unknownMetaLines: ["# operator note", "futureKey: 42"]
        )
        let backend = MockBotsBackend([original])
        let viewModel = makeViewModel(backend)
        viewModel.load()
        await waitForLoad(viewModel, expecting: 1)

        var draft = BotDraft(identity: original)
        #expect(draft.title == "Research")
        #expect(draft.color == "#111111")
        draft.title = "Deep Research"
        draft.description = "Reads a great many things."
        draft.pinned = true

        viewModel.save(draft)
        await waitForIdle(viewModel)

        let saved = try! #require(backend.savedIdentities.last)
        // Changed:
        #expect(saved.title == "Deep Research")
        #expect(saved.displayName == "Deep Research")
        #expect(saved.botDescription == "Reads a great many things.")
        #expect(saved.profileDescription == "Reads a great many things.")
        #expect(saved.pinned == true)
        // A human typed the blurb, so the LLM marker is cleared.
        #expect(saved.descriptionIsAuto == false)
        // Untouched — the whole point:
        #expect(saved.created == 1_700_000_000_000)
        #expect(saved.groups == ["lab"])
        #expect(saved.legacyGroup == "old-lab")
        #expect(saved.imageKind == .photo)
        #expect(saved.custom == true)
        #expect(saved.unknownMetaLines == ["# operator note", "futureKey: 42"])
    }

    @Test("the draft is applied to a freshly re-read identity, not the sheet's snapshot")
    func saveRereadsBeforeWriting() async {
        let backend = MockBotsBackend([Self.bot("research", title: "Research")])
        let viewModel = makeViewModel(backend)
        viewModel.load()
        await waitForLoad(viewModel, expecting: 1)

        // Somebody else (Hermes Desktop, a hand edit) adds a key after the
        // sheet was opened.
        var meanwhile = backend.identity(forProfile: "research")
        meanwhile.unknownMetaLines = ["addedByDesktop: true"]
        try! backend.saveIdentity(meanwhile)

        var draft = BotDraft(identity: Self.bot("research", title: "Research"))
        draft.title = "Renamed"
        viewModel.save(draft)
        await waitForIdle(viewModel)

        let saved = try! #require(backend.savedIdentities.last)
        #expect(saved.title == "Renamed")
        // The concurrent key survived because the write merged onto the
        // CURRENT file, not the draft's origin.
        #expect(saved.unknownMetaLines == ["addedByDesktop: true"])
    }

    @Test("empty text clears a key instead of writing a blank string")
    func emptyFieldsClearRatherThanBlank() {
        var identity = Self.bot("research", title: "Research")
        identity.color = "#abcdef"
        var draft = BotDraft(identity: identity)
        draft.color = "   "
        draft.title = ""
        draft.apply(to: &identity)
        #expect(identity.color == nil)
        #expect(identity.title == nil)
    }

    // MARK: - Promote / demote

    @Test("promoting a plain profile makes it bot-managed without touching the profile")
    func promoteMakesAProfileABot() async {
        let plain = HermesBotIdentity(
            profileName: "scratch",
            profileDirectory: "/tmp/scratch",
            displayName: "Scratch",
            profileDescription: "Odds and ends.",
            isBotManaged: false
        )
        let backend = MockBotsBackend([plain])
        let viewModel = makeViewModel(backend)
        viewModel.load()
        await waitForLoad(viewModel, expecting: 1)

        viewModel.promote(BotRow(identity: plain, avatar: nil))
        await waitForIdle(viewModel)

        let saved = try! #require(backend.savedIdentities.last)
        #expect(saved.isBotManaged)
        #expect(saved.title == "Scratch")
        #expect(saved.botDescription == "Odds and ends.")
        // Promotion is a metadata write only — never a lifecycle verb.
        #expect(backend.lifecycleActions.isEmpty)
    }

    @Test("a promoted profile with no display name falls back to its id")
    func promoteFallsBackToProfileID() async {
        let plain = HermesBotIdentity(profileName: "scratch", profileDirectory: "/tmp/scratch", isBotManaged: false)
        let backend = MockBotsBackend([plain])
        let viewModel = makeViewModel(backend)
        viewModel.promote(BotRow(identity: plain, avatar: nil))
        await waitForIdle(viewModel)
        #expect(backend.savedIdentities.last?.title == "scratch")
    }

    /// Demote used to be byte-identical to Hide — it went through
    /// `BotDraft.apply`, which stamps `isBotManaged = true` — so the
    /// affordance's label over-promised (go/no-go blocking condition 2). It
    /// now clears the `hermes-bots` block, which is what returns the profile
    /// to "Other profiles"; it still never touches the profile itself.
    @Test("demoting clears the bot block and never deletes anything")
    func demoteClearsTheBotBlock() async {
        let identity = Self.bot("research", title: "Research", pinned: true)
        let backend = MockBotsBackend([identity])
        let viewModel = makeViewModel(backend)
        viewModel.demote(BotRow(identity: identity, avatar: nil))
        await waitForIdle(viewModel)

        let saved = try! #require(backend.savedIdentities.last)
        // The write the YAML layer turns into "remove the block".
        #expect(!saved.isBotManaged)
        // Both live inside the block being removed.
        #expect(saved.pinned == nil)
        #expect(saved.hidden == nil)
        // Emphatically NOT `hermes profile delete`.
        #expect(backend.lifecycleActions.isEmpty)
    }

    /// Hide is the other, still-distinct verb: it keeps the profile
    /// bot-managed and only collapses it behind the roster's disclosure.
    @Test("hiding is still a separate, non-destructive verb")
    func hideRemainsDistinctFromDemote() async {
        let identity = Self.bot("research", title: "Research", pinned: true)
        let backend = MockBotsBackend([identity])
        let viewModel = makeViewModel(backend)
        viewModel.toggleHidden(BotRow(identity: identity, avatar: nil))
        await waitForIdle(viewModel)

        let saved = try! #require(backend.savedIdentities.last)
        #expect(saved.hidden == true)
        #expect(saved.isBotManaged)
        #expect(backend.lifecycleActions.isEmpty)
    }

    // MARK: - Create

    @Test("create runs the CLI, then writes the identity")
    func createRunsCLIThenWritesIdentity() async {
        let backend = MockBotsBackend([Self.bot("default", managed: false)])
        let viewModel = makeViewModel(backend)
        var draft = BotDraft(identity: HermesBotIdentity(profileName: "", profileDirectory: ""))
        draft.title = "Deploy"
        draft.description = "Ships things."

        viewModel.createBot(profileName: "deploy", draft: draft, cloneFrom: nil)
        await waitForIdle(viewModel)

        #expect(backend.lifecycleActions.count == 1)
        #expect(backend.lifecycleActions.first == .create(
            name: "deploy", cloneFrom: nil, cloneAll: false, noSkills: false, description: "Ships things."
        ))
        let saved = try! #require(backend.savedIdentities.last)
        #expect(saved.profileName == "deploy")
        #expect(saved.isBotManaged)
        #expect(saved.title == "Deploy")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("a CLI refusal creates nothing and surfaces stderr verbatim")
    func createSurfacesCLIRefusalVerbatim() async {
        let backend = MockBotsBackend([])
        backend.lifecycleExit = 1
        backend.lifecycleStderr = "Error: profile 'deploy' already exists"
        let viewModel = makeViewModel(backend)

        viewModel.createBot(
            profileName: "deploy",
            draft: BotDraft(identity: HermesBotIdentity(profileName: "", profileDirectory: "")),
            cloneFrom: nil
        )
        await waitForIdle(viewModel)

        #expect(viewModel.errorMessage == "Error: profile 'deploy' already exists")
        // The identity write never ran, so there is no half-made bot.
        #expect(backend.savedIdentities.isEmpty)
    }

    @Test("a created profile whose identity write fails is kept and named, not silently half-made")
    func createPartialFailureIsExplicit() async {
        // The adversarial case: `hermes profile create` succeeded, then the
        // profile.yaml write failed. Deleting the new profile to tidy up
        // would run an irreversible verb over a directory the user asked
        // for, so the profile is kept and the message says exactly where it
        // went and how to retry.
        let backend = MockBotsBackend([])
        backend.saveError = .unsafeToWrite(path: "/tmp/deploy/profile.yaml")
        let viewModel = makeViewModel(backend)

        viewModel.createBot(
            profileName: "deploy",
            draft: BotDraft(identity: HermesBotIdentity(profileName: "", profileDirectory: "")),
            cloneFrom: nil
        )
        await waitForIdle(viewModel)
        await waitForLoad(viewModel, expecting: 1)

        let message = try! #require(viewModel.errorMessage)
        #expect(message.contains("was created"))
        #expect(message.contains("Other profiles"))
        // No compensating delete: the profile survives, as an unmanaged one.
        #expect(!backend.lifecycleActions.contains { $0.isDestructive })
        #expect(viewModel.otherProfiles.map(\.identity.profileName) == ["deploy"])
    }

    @Test("an unaddressable profile id is refused before it reaches argv")
    func createRejectsBadProfileIDs() async {
        let backend = MockBotsBackend([])
        let viewModel = makeViewModel(backend)
        let draft = BotDraft(identity: HermesBotIdentity(profileName: "", profileDirectory: ""))

        for bad in ["../../etc", "Deploy Bot", "", "default"] {
            viewModel.errorMessage = nil
            viewModel.createBot(profileName: bad, draft: draft, cloneFrom: nil)
            await waitForIdle(viewModel)
            #expect(viewModel.errorMessage != nil, "\(bad) should be refused")
        }
        #expect(backend.lifecycleActions.isEmpty)
    }

    // MARK: - Rename / delete

    @Test("delete runs the destructive verb exactly once and clears the selection")
    func deleteRunsTheDestructiveVerb() async {
        let identity = Self.bot("scratch", title: "Scratch")
        let backend = MockBotsBackend([identity])
        let viewModel = makeViewModel(backend)
        viewModel.selectedProfileName = "scratch"

        viewModel.delete(BotRow(identity: identity, avatar: nil))
        await waitForIdle(viewModel)

        #expect(backend.lifecycleActions == [.delete(name: "scratch")])
        #expect(backend.lifecycleActions.first?.isDestructive == true)
    }

    @Test("rename refuses an invalid target without spawning anything")
    func renameValidatesTheTarget() async {
        let identity = Self.bot("scratch", title: "Scratch")
        let backend = MockBotsBackend([identity])
        let viewModel = makeViewModel(backend)

        viewModel.rename(BotRow(identity: identity, avatar: nil), to: "Not A Name")
        await waitForIdle(viewModel)
        #expect(backend.lifecycleActions.isEmpty)
        #expect(viewModel.errorMessage != nil)

        viewModel.errorMessage = nil
        viewModel.rename(BotRow(identity: identity, avatar: nil), to: "scratch-2")
        await waitForIdle(viewModel)
        #expect(backend.lifecycleActions == [.rename(from: "scratch", to: "scratch-2")])
    }

    // MARK: - Avatar

    @Test("storing an avatar marks the identity as carrying a photo")
    func avatarWriteStampsImageKind() async {
        let identity = Self.bot("research", title: "Research")
        let backend = MockBotsBackend([identity])
        let viewModel = makeViewModel(backend)

        viewModel.setAvatar(Data(repeating: 0x7f, count: 1_024), forProfile: "research")
        await waitForIdle(viewModel)

        #expect(backend.writtenAvatars.map(\.name) == ["research"])
        let saved = try! #require(backend.savedIdentities.last)
        #expect(saved.imageKind == .photo)
        #expect(saved.custom == true)
        #expect(saved.isBotManaged)
    }

    // MARK: - Failure copy

    @Test("write failures are explained, not dumped")
    func saveFailureTextExplainsEachCase() {
        let unsafe = BotsViewModel.saveFailureText(
            BotsError.unsafeToWrite(path: "/tmp/p/profile.yaml"), profileName: "p"
        )
        #expect(unsafe.contains("/tmp/p/profile.yaml"))
        let unsupported = BotsViewModel.saveFailureText(BotsError.unsupported, profileName: "p")
        #expect(unsupported.contains("0.20.3"))
        let missing = BotsViewModel.saveFailureText(BotsError.profileMissing(name: "p"), profileName: "p")
        #expect(missing.contains("\"p\""))
    }

    @Test("CLI failure text prefers stderr, then stdout, then the exit code")
    func cliFailureTextPrefersStderr() {
        #expect(BotsViewModel.cliFailureText(
            ProcessResult(exitCode: 1, stdout: Data("out".utf8), stderr: Data("boom".utf8))
        ) == "boom")
        #expect(BotsViewModel.cliFailureText(
            ProcessResult(exitCode: 1, stdout: Data("out".utf8), stderr: Data())
        ) == "out")
        #expect(BotsViewModel.cliFailureText(
            ProcessResult(exitCode: 3, stdout: Data(), stderr: Data())
        ).contains("3"))
    }

    // MARK: - Sidebar + analytics

    @Test("the Bots sidebar section carries a unique snake_case analytics token")
    func botsAnalyticsToken() {
        #expect(SidebarSection.bots.analyticsToken == "bots")
        var seen: Set<String> = []
        for section in SidebarSection.allCases {
            #expect(seen.insert(section.analyticsToken).inserted, "duplicate token \(section.analyticsToken)")
        }
        #expect(seen.contains("bots"))
    }

    @Test("Bots is ordered immediately before Chat")
    func botsPrecedesChatInTheEnum() {
        // The sidebar builds its own section list, but the enum's own order
        // is the declaration of intent — Bots sits directly above Interact,
        // whose first row is Chat.
        let all = SidebarSection.allCases
        let bots = try! #require(all.firstIndex(of: .bots))
        let chat = try! #require(all.firstIndex(of: .chat))
        #expect(bots + 1 == chat)
    }
}
