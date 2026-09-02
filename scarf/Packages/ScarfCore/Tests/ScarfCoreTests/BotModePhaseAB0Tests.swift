import Testing
import Foundation
@testable import ScarfCore

/// B0 of the Bot Mode Phase A cycle — the ScarfCore domain layer.
///
/// Pinned against real Hermes source at the audited tag v2026.8.31
/// (Hermes 0.21.0):
/// - `tools/bot_mode_probe.py:60-92` — `_is_bot_managed` (a `ui_meta`
///   `hermes-bots` **mapping**) and `_roster` (default profile + sorted
///   children of `<root>/profiles`).
/// - `hermes_cli/profiles.py:920-991` — `profile.yaml`'s top-level keys and
///   Hermes' own read/write semantics (empty `display_name` pops the key).
/// - `hermes_cli/subcommands/profile.py:29-131` — `create` / `delete` /
///   `rename` argv.
/// - `tui_gateway/methods_profiles.py:780-863, 1020+` — the 64KB `ui_meta`
///   cap and the 2MB avatar cap.
/// - `apps/desktop/src/plugins/hermes-bots/types.ts` — the `BotMeta` field
///   set, including the legacy `group` scalar alongside `groups`.
///
/// The filesystem-facing suite drives a real `LocalTransport` against a
/// temporary profile tree, the same way W6/W9 did, so the paths exercised are
/// the ones the SSH transport implements too.
@Suite struct BotModePhaseAB0Tests {

    // MARK: - Fixtures

    /// A fully-populated bot-managed profile, in the shape PyYAML's
    /// `safe_dump` produces plus a comment and an unmodeled key.
    static let managedYAML = """
    # Written by Hermes Desktop — do not hand-edit
    display_name: Athena
    description: Research and long-form synthesis.
    description_auto: false
    ui_meta:
      shared-room:
        messages:
          - hello
      hermes-bots:
        title: Athena
        color: '#7B61FF'
        shape: blob-3
        imageKind: shape
        custom: true
        hidden: false
        pinned: true
        groups:
          - research
          - writing
        created: 1756000000000
        futureKey: something a newer desktop wrote
    """

    static let unmanagedYAML = """
    description: Just an ordinary profile.
    description_auto: true
    """

    // MARK: - Parsing

    @Test func parsesEveryModeledBotMetaField() {
        let id = HermesBotProfileYAML.parse(Self.managedYAML, profileName: "athena", profileDirectory: "/h/profiles/athena")
        #expect(id.isBotManaged)
        #expect(id.displayName == "Athena")
        #expect(id.profileDescription == "Research and long-form synthesis.")
        #expect(id.descriptionIsAuto == false)
        #expect(id.title == "Athena")
        #expect(id.color == "#7B61FF")
        #expect(id.shape == "blob-3")
        #expect(id.imageKind == .shape)
        #expect(id.custom == true)
        #expect(id.hidden == false)
        #expect(id.pinned == true)
        #expect(id.groups == ["research", "writing"])
        #expect(id.created == 1_756_000_000_000)
        #expect(id.resolvedTitle == "Athena")
    }

    @Test func unknownKeysAndCommentsArePreservedForRoundTrip() {
        let id = HermesBotProfileYAML.parse(Self.managedYAML, profileName: "athena", profileDirectory: "/x")
        #expect(id.unknownMetaLines.contains("futureKey: something a newer desktop wrote"))
    }

    @Test func unmanagedProfileIsNotABot() {
        let id = HermesBotProfileYAML.parse(Self.unmanagedYAML, profileName: "plain", profileDirectory: "/x")
        #expect(!id.isBotManaged)
        #expect(id.descriptionIsAuto)
        // Falls back to the canonical id, like `format_profile_label`.
        #expect(id.resolvedTitle == "plain")
    }

    @Test func bareBotsHeaderIsNotAMappingAndSoNotBotManaged() {
        // PyYAML loads `hermes-bots:` with no body as None, which fails
        // `isinstance(..., dict)` in `_is_bot_managed`.
        let id = HermesBotProfileYAML.parse("ui_meta:\n  hermes-bots:\n", profileName: "p", profileDirectory: "/x")
        #expect(!id.isBotManaged)
    }

    @Test func emptyFlowMappingIsBotManaged() {
        let id = HermesBotProfileYAML.parse("ui_meta:\n  hermes-bots: {}\n", profileName: "p", profileDirectory: "/x")
        #expect(id.isBotManaged)
        #expect(id.title == nil)
    }

    @Test func malformedYAMLDegradesToAnUnmanagedIdentity() {
        // The exact corruption `tests/tools/test_bot_mode_probe.py:125` uses.
        let id = HermesBotProfileYAML.parse("ui_meta: [unclosed", profileName: "broken", profileDirectory: "/x")
        #expect(!id.isBotManaged)
        #expect(id.profileName == "broken")
    }

    @Test func legacyGroupScalarSurvivesAlongsideGroupsList() {
        let both = HermesBotProfileYAML.parse("""
        ui_meta:
          hermes-bots:
            group: research
            groups:
              - research
              - ops
        """, profileName: "p", profileDirectory: "/x")
        #expect(both.legacyGroup == "research")
        #expect(both.groups == ["research", "ops"])
        // The legacy scalar is already in the list — no duplicate row.
        #expect(both.effectiveGroups == ["research", "ops"])

        let legacyOnly = HermesBotProfileYAML.parse("""
        ui_meta:
          hermes-bots:
            group: solo
        """, profileName: "p", profileDirectory: "/x")
        #expect(legacyOnly.groups.isEmpty)
        #expect(legacyOnly.effectiveGroups == ["solo"])
    }

    @Test func nullLegacyGroupClearsRatherThanStoringTheWordNull() {
        let id = HermesBotProfileYAML.parse("""
        ui_meta:
          hermes-bots:
            group: null
        """, profileName: "p", profileDirectory: "/x")
        #expect(id.legacyGroup == nil)
        #expect(id.isBotManaged)
    }

    @Test func flowStyleGroupsListParses() {
        let id = HermesBotProfileYAML.parse("""
        ui_meta:
          hermes-bots:
            groups: [a, b]
        """, profileName: "p", profileDirectory: "/x")
        #expect(id.groups == ["a", "b"])
    }

    @Test func botTitleWinsOverDisplayNameWhichWinsOverTheId() {
        var id = HermesBotIdentity(profileName: "athena", profileDirectory: "/x")
        #expect(id.resolvedTitle == "athena")
        id.displayName = "Athena Prime"
        #expect(id.resolvedTitle == "Athena Prime")
        id.title = "Athena"
        #expect(id.resolvedTitle == "Athena")
    }

    @Test func unrecognizedImageKindIsPreservedNotCoerced() {
        let id = HermesBotProfileYAML.parse("""
        ui_meta:
          hermes-bots:
            imageKind: hologram
        """, profileName: "p", profileDirectory: "/x")
        #expect(id.imageKind == .other("hologram"))
        #expect(id.imageKind?.rawValue == "hologram")
    }

    // MARK: - Write preservation

    @Test func roundTripPreservesEverythingScarfDoesNotOwn() throws {
        let id = HermesBotProfileYAML.parse(Self.managedYAML, profileName: "athena", profileDirectory: "/x")
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: Self.managedYAML))

        // The sibling ui_meta key and the file's leading comment are untouched.
        #expect(out.contains("# Written by Hermes Desktop — do not hand-edit"))
        #expect(out.contains("shared-room:"))
        #expect(out.contains("      - hello"))
        // The unmodeled bot key survives.
        #expect(out.contains("futureKey: something a newer desktop wrote"))

        // And a re-parse is identical to the first — the real preservation
        // test, since it covers ordering-independent equality of every field.
        let again = HermesBotProfileYAML.parse(out, profileName: "athena", profileDirectory: "/x")
        #expect(again == id)

        // Idempotent: a second write changes nothing at all.
        #expect(HermesBotProfileYAML.write(identity: again, into: out) == out)
    }

    @Test func editingATitleChangesOnlyThatLine() throws {
        var id = HermesBotProfileYAML.parse(Self.managedYAML, profileName: "athena", profileDirectory: "/x")
        id.title = "Athena II"
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: Self.managedYAML))
        #expect(out.contains("title: Athena II"))
        #expect(!out.contains("title: Athena\n"))
        #expect(out.contains("shared-room:"))
    }

    @Test func clearingDisplayNameRemovesTheKeyAsHermesDoes() throws {
        var id = HermesBotProfileYAML.parse(Self.managedYAML, profileName: "athena", profileDirectory: "/x")
        id.displayName = ""
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: Self.managedYAML))
        #expect(!out.contains("display_name"))
    }

    @Test func promotingAnOrdinaryProfileToABotAddsTheBlock() throws {
        var id = HermesBotProfileYAML.parse(Self.unmanagedYAML, profileName: "plain", profileDirectory: "/x")
        id.isBotManaged = true
        id.title = "Plainly a bot"
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: Self.unmanagedYAML))
        let reparsed = HermesBotProfileYAML.parse(out, profileName: "plain", profileDirectory: "/x")
        #expect(reparsed.isBotManaged)
        #expect(reparsed.title == "Plainly a bot")
        #expect(reparsed.profileDescription == "Just an ordinary profile.")
    }

    @Test func promotingWithNoMetadataStillReadsBackAsManaged() throws {
        var id = HermesBotIdentity(profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: ""))
        // A bare header would be None to PyYAML — not a dict, not a bot.
        #expect(out.contains("hermes-bots: {}"))
        #expect(HermesBotProfileYAML.parse(out, profileName: "p", profileDirectory: "/x").isBotManaged)
    }

    @Test func demotingRemovesTheBotBlockButKeepsSiblingUIMeta() throws {
        var id = HermesBotProfileYAML.parse(Self.managedYAML, profileName: "athena", profileDirectory: "/x")
        id.isBotManaged = false
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: Self.managedYAML))
        #expect(!out.contains("hermes-bots"))
        #expect(out.contains("shared-room:"))
        #expect(out.contains("display_name: Athena"))
    }

    @Test func writerRefusesAPopulatedInlineUIMetaRatherThanClobberIt() {
        var id = HermesBotIdentity(profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        #expect(HermesBotProfileYAML.write(identity: id, into: "ui_meta: {shared-room: {a: 1}}\n") == nil)
    }

    @Test func writerRefusesDuplicateTopLevelUIMeta() {
        var id = HermesBotIdentity(profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        let yaml = "ui_meta:\n  a: 1\nui_meta:\n  b: 2\n"
        #expect(HermesBotProfileYAML.write(identity: id, into: yaml) == nil)
    }

    @Test func writerRefusesAnOversizedBotBlock() {
        var id = HermesBotIdentity(profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        // Mirrors the gateway's own 64KB `ui_meta` guard, which rejects the
        // write rather than truncating.
        id.botDescription = String(repeating: "x", count: HermesBotProfileYAML.maxBotMetaBytes + 1)
        #expect(HermesBotProfileYAML.write(identity: id, into: "") == nil)

        id.botDescription = String(repeating: "x", count: 1024)
        #expect(HermesBotProfileYAML.write(identity: id, into: "") != nil)
    }

    @Test func crlfFilesRoundTripAsCRLF() throws {
        let crlf = Self.managedYAML.replacingOccurrences(of: "\n", with: "\r\n")
        let id = HermesBotProfileYAML.parse(crlf, profileName: "athena", profileDirectory: "/x")
        #expect(id.title == "Athena")
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: crlf))
        #expect(out.contains("\r\n"))
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func titlesNeedingQuotesGetThem() throws {
        var id = HermesBotIdentity(profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        id.title = "true"
        id.botDescription = "role: analyst"
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: ""))
        #expect(out.contains("title: 'true'"))
        #expect(out.contains("description: 'role: analyst'"))
        let again = HermesBotProfileYAML.parse(out, profileName: "p", profileDirectory: "/x")
        #expect(again.title == "true")
        #expect(again.botDescription == "role: analyst")
    }

    // MARK: - Capability gating

    @Test func botModeFloorIsV0203NotV021() {
        func caps(_ line: String) -> HermesCapabilities { HermesCapabilities.parseLine(line) }
        #expect(!caps("Hermes Agent v0.20.2 (2026.8.16)").hasBotMode)
        #expect(caps("Hermes Agent v0.20.3 (2026.8.16)").hasBotMode)
        #expect(caps("Hermes Agent v0.20.5 (2026.8.19)").hasBotMode)
        #expect(caps("Hermes Agent v0.21.0 (2026.8.31)").hasBotMode)
        // Undetected host: every flag false, so no Bots surface renders.
        #expect(!HermesCapabilities.empty.hasBotMode)
    }

    // MARK: - Lifecycle argv

    @Test func lifecycleArgvMatchesTheArgparse() {
        #expect(BotsService.Lifecycle.create(
            name: "athena", cloneFrom: nil, cloneAll: false, noSkills: false, description: nil
        ).argv == ["profile", "create", "athena"])

        #expect(BotsService.Lifecycle.create(
            name: "athena", cloneFrom: "template", cloneAll: false, noSkills: true, description: "Researcher."
        ).argv == ["profile", "create", "athena", "--clone-from", "template", "--no-skills", "--description", "Researcher."])

        // `--clone-from` implies `--clone` unless `--clone-all` is set, so
        // `--clone` is never emitted alongside either.
        #expect(BotsService.Lifecycle.create(
            name: "athena", cloneFrom: "template", cloneAll: true, noSkills: false, description: nil
        ).argv == ["profile", "create", "athena", "--clone-all", "--clone-from", "template"])

        // No TTY to answer the prompt on, so `--yes` is mandatory — and the
        // confirmation therefore belongs entirely to the UI.
        #expect(BotsService.Lifecycle.delete(name: "athena").argv == ["profile", "delete", "athena", "--yes"])
        #expect(BotsService.Lifecycle.rename(from: "a", to: "b").argv == ["profile", "rename", "a", "b"])
    }

    @Test func onlyDeletionIsMarkedDestructive() {
        #expect(BotsService.Lifecycle.delete(name: "x").isDestructive)
        #expect(!BotsService.Lifecycle.rename(from: "a", to: "b").isDestructive)
        #expect(!BotsService.Lifecycle.create(
            name: "x", cloneFrom: nil, cloneAll: false, noSkills: false, description: nil
        ).isDestructive)
    }

    // MARK: - Transport-driven scanning

    /// Build a temp Hermes root and hand back a service wired to a real
    /// `LocalTransport` — the same transport protocol the SSH backend
    /// implements, so a path that works here works remotely.
    private func makeService(
        version: String = "Hermes Agent v0.21.0 (2026.8.31)"
    ) throws -> (service: BotsService, root: String) {
        let root = NSTemporaryDirectory() + "scarf-bots-\(UUID().uuidString)/.hermes"
        try FileManager.default.createDirectory(atPath: root + "/profiles", withIntermediateDirectories: true)
        let service = BotsService(
            transport: LocalTransport(),
            paths: HermesPathSet(home: root, isRemote: false, binaryHint: nil),
            capabilities: HermesCapabilities.parseLine(version)
        )
        return (service, root)
    }

    private func write(_ contents: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func scanReturnsDefaultFirstThenSortedNamedProfiles() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }

        try write(Self.managedYAML, to: root + "/profiles/zeta/profile.yaml")
        try write(Self.unmanagedYAML, to: root + "/profiles/alpha/profile.yaml")
        try write("ui_meta: [unclosed", to: root + "/profiles/broken/profile.yaml")
        // A file, not a directory, under profiles/ — must not become a row.
        try write("noise", to: root + "/profiles/README.md")

        let roster = service.scan()
        #expect(roster.map(\.profileName) == ["default", "alpha", "broken", "zeta"])
        #expect(roster.first(where: { $0.profileName == "zeta" })?.isBotManaged == true)
        #expect(roster.first(where: { $0.profileName == "alpha" })?.isBotManaged == false)
        // One malformed file must never empty the roster.
        #expect(roster.first(where: { $0.profileName == "broken" })?.isBotManaged == false)
        // The default profile has no profile.yaml here and still appears.
        #expect(roster.first?.profileName == "default")
        #expect(roster.first?.profileDirectory == root)
    }

    @Test func rosterIsRootedAtTheRootHomeEvenWhenTheWindowIsScopedToAProfile() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try write(Self.managedYAML, to: root + "/profiles/athena/profile.yaml")

        // A window pointed at `<root>/profiles/athena` must still see the
        // whole roster: `profiles/` only exists at the root, and a naive
        // `paths.home + "/profiles"` would look for
        // `<root>/profiles/athena/profiles`.
        let scoped = BotsService(
            transport: LocalTransport(),
            paths: HermesPathSet(home: root + "/profiles/athena", isRemote: false, binaryHint: nil),
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
        )
        #expect(scoped.rootHome == root)
        #expect(scoped.scan().map(\.profileName) == ["default", "athena"])
    }

    @Test func saveIdentityMergesThroughTheTransportAndKeepsForeignKeys() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let path = root + "/profiles/athena/profile.yaml"
        try write(Self.managedYAML, to: path)

        var id = service.identity(forProfile: "athena")
        id.pinned = false
        id.groups = ["research"]
        try service.saveIdentity(id)

        let onDisk = try String(contentsOfFile: path, encoding: .utf8)
        #expect(onDisk.contains("shared-room:"))
        #expect(onDisk.contains("futureKey: something a newer desktop wrote"))
        let reread = service.identity(forProfile: "athena")
        #expect(reread.pinned == false)
        #expect(reread.groups == ["research"])
        #expect(reread.color == "#7B61FF")
    }

    @Test func saveIsRefusedBelowTheBotModeFloor() throws {
        let (service, root) = try makeService(version: "Hermes Agent v0.20.2 (2026.8.16)")
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try write(Self.managedYAML, to: root + "/profiles/athena/profile.yaml")
        var id = service.identity(forProfile: "athena")
        id.title = "Nope"
        #expect(throws: BotsError.unsupported) { try service.saveIdentity(id) }
    }

    @Test func saveIsRefusedForAMissingProfile() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let id = HermesBotIdentity(profileName: "ghost", profileDirectory: service.directory(forProfile: "ghost"))
        #expect(throws: BotsError.profileMissing(name: "ghost")) { try service.saveIdentity(id) }
    }

    @Test func avatarIsFoundInTheGatewaysProbeOrderAndCappedAt2MB() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let assets = root + "/profiles/athena/assets"
        try FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true)

        #expect(!service.hasAvatar(forProfile: "athena"))
        #expect(try service.loadAvatar(forProfile: "athena") == nil)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 16)
        try png.write(to: URL(fileURLWithPath: assets + "/avatar.png"))
        try Data(repeating: 1, count: 4).write(to: URL(fileURLWithPath: assets + "/avatar.webp"))

        let avatar = try #require(try service.loadAvatar(forProfile: "athena"))
        // png before webp, matching the gateway's own dict iteration order.
        #expect(avatar.mimeType == "image/png")
        #expect(avatar.data == png)

        // Over the gateway's own 2MB ceiling: refused on the stat, so the
        // bytes never cross the transport.
        let big = Data(repeating: 0, count: HermesBotAvatar.maxBytes + 1)
        try big.write(to: URL(fileURLWithPath: assets + "/avatar.png"))
        #expect(throws: BotsError.self) { try service.loadAvatar(forProfile: "athena") }
    }

    // MARK: - Audit regressions

    @Test func aHermesBotsKeyNestedInAnotherNamespaceIsNotOurs() {
        // `ui_meta` is one namespace per client. A `hermes-bots` key inside a
        // SIBLING namespace belongs to that client; reading it would invent a
        // bot and writing through it would corrupt their block.
        let yaml = """
        ui_meta:
          shared-room:
            hermes-bots:
              title: not a bot
        """
        let id = HermesBotProfileYAML.parse(yaml, profileName: "p", profileDirectory: "/x")
        #expect(!id.isBotManaged)
        #expect(id.title == nil)

        var promoted = id
        promoted.isBotManaged = true
        promoted.title = "Real"
        let out = try! #require(HermesBotProfileYAML.write(identity: promoted, into: yaml))
        // The foreign block is untouched and a real sibling key was added.
        #expect(out.contains("      title: not a bot"))
        #expect(HermesBotProfileYAML.parse(out, profileName: "p", profileDirectory: "/x").title == "Real")
    }

    @Test func anUnreadableProfileYAMLIsNeverUsedAsAMergeBase() throws {
        // The read path degrades an oversized/corrupt file to "no metadata"
        // for DISPLAY. Merging into that emptiness would replace the user's
        // file with a stub — so the write path must refuse instead.
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let path = root + "/profiles/huge/profile.yaml"
        let payload = Self.managedYAML + "\n# " + String(repeating: "x", count: BotsService.maxProfileYAMLBytes)
        try write(payload, to: path)

        var id = service.identity(forProfile: "huge")
        id.isBotManaged = true
        id.title = "Clobber"
        #expect(throws: BotsError.unsafeToWrite(path: path)) { try service.saveIdentity(id) }
        // Still byte-identical on disk.
        #expect(try String(contentsOfFile: path, encoding: .utf8) == payload)
    }

    @Test func aMalformedProfileNameCannotBeWrittenOrShelledOut() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        // `resolveHome` fails SAFE to the root home for an invalid name, which
        // for a write would mean silently editing the default profile.
        #expect(service.directory(forProfile: "../../etc") == service.rootHome)
        #expect(!BotsService.isAddressableProfile("../../etc"))
        #expect(BotsService.isAddressableProfile("default"))
        #expect(BotsService.isAddressableProfile("athena-2"))

        let id = HermesBotIdentity(profileName: "../../etc", profileDirectory: "/x")
        #expect(throws: BotsError.profileMissing(name: "../../etc")) { try service.saveIdentity(id) }
        #expect(throws: BotsError.profileMissing(name: "Bad Name")) {
            try service.run(.rename(from: "athena", to: "Bad Name"))
        }
    }

    @Test func oversizedProfileYAMLIsNotRead() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let path = root + "/profiles/huge/profile.yaml"
        try write(
            Self.managedYAML + "\n# " + String(repeating: "x", count: BotsService.maxProfileYAMLBytes),
            to: path
        )
        // Degrades to an unmanaged identity rather than pulling a megabyte-plus
        // file over a possibly-remote transport.
        #expect(!service.identity(forProfile: "huge").isBotManaged)
    }
}

/// Regression cover for the "created, but its bot details couldn't be saved"
/// bug: `hermes profile create --description "<a sentence>"` produces a
/// `profile.yaml` the writer refused to touch, so EVERY bot created with a
/// role longer than `safe_dump`'s 80-column wrap width failed its identity
/// write and landed in "Other profiles".
@Suite struct BotModeCreatedProfileWriteTests {

    /// Byte-for-byte what `hermes profile create seo-research-bot
    /// --description "…"` wrote on the reporting machine (Hermes 0.21.0).
    /// The description is a single logical line that `yaml.safe_dump` wrapped
    /// at width 80 into a multi-line PLAIN scalar — note there is no
    /// `display_name`, no `ui_meta`, and no quoting.
    static let freshlyCreatedYAML = """
    description: You are an SEO analyst that will keep an eye on a website (https://shabubox.com)
      as well as search terms that are used to find or potentially find the site through
      search, and make recommendations on changes, additions, etc for the site.
    description_auto: false

    """

    static let foldedDescription =
        "You are an SEO analyst that will keep an eye on a website (https://shabubox.com) "
        + "as well as search terms that are used to find or potentially find the site through "
        + "search, and make recommendations on changes, additions, etc for the site."

    private func makeService() throws -> (service: BotsService, root: String) {
        let root = NSTemporaryDirectory() + "scarf-bots-\(UUID().uuidString)/.hermes"
        try FileManager.default.createDirectory(atPath: root + "/profiles", withIntermediateDirectories: true)
        return (
            BotsService(
                transport: LocalTransport(),
                paths: HermesPathSet(home: root, isRemote: false, binaryHint: nil),
                capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
            ),
            root
        )
    }

    private func write(_ contents: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - The reported bug

    @Test func aWrappedDescriptionReadsBackAsOneFoldedLine() {
        // Before the fix the reader saw only the key's own line and silently
        // truncated the role at the wrap point — which would have made the
        // writer fix a data-loss bug instead of a save.
        let id = HermesBotProfileYAML.parse(
            Self.freshlyCreatedYAML, profileName: "seo-research-bot", profileDirectory: "/x"
        )
        #expect(id.profileDescription == Self.foldedDescription)
        #expect(id.descriptionIsAuto == false)
        #expect(id.isBotManaged == false)
    }

    @Test func makeABotSucceedsOnAFreshlyCreatedProfile() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let path = root + "/profiles/seo-research-bot/profile.yaml"
        try write(Self.freshlyCreatedYAML, to: path)

        var id = service.identity(forProfile: "seo-research-bot")
        id.isBotManaged = true
        id.title = "seo-research-bot"
        // This threw `unsafeToWrite` before the fix.
        try service.saveIdentity(id)

        let round = HermesBotProfileYAML.parse(
            try String(contentsOfFile: path, encoding: .utf8),
            profileName: "seo-research-bot", profileDirectory: "/x"
        )
        #expect(round.isBotManaged)
        #expect(round.title == "seo-research-bot")
        // The wrapped role survives the rewrite intact.
        #expect(round.profileDescription == Self.foldedDescription)
    }

    @Test func createWithAnEmptyOptionalNameWritesIdentity() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let path = root + "/profiles/seo-research-bot/profile.yaml"
        try write(Self.freshlyCreatedYAML, to: path)

        // An empty optional profile-name field means "no display_name" — the
        // key is POPPED, exactly as Hermes' own writer does, not written as "".
        var id = service.identity(forProfile: "seo-research-bot")
        id.isBotManaged = true
        id.displayName = ""
        id.title = "seo-research-bot"
        try service.saveIdentity(id)

        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains("display_name"))
        #expect(HermesBotProfileYAML.parse(text, profileName: "seo-research-bot", profileDirectory: "/x").isBotManaged)
    }

    // MARK: - The two states the create flow can also land in

    @Test func createWithAnAbsentProfileYAMLWritesFromEmpty() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let dir = root + "/profiles/no-yaml"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var id = service.identity(forProfile: "no-yaml")
        id.isBotManaged = true
        id.title = "Fresh"
        try service.saveIdentity(id)

        let text = try String(contentsOfFile: dir + "/profile.yaml", encoding: .utf8)
        #expect(HermesBotProfileYAML.parse(text, profileName: "no-yaml", profileDirectory: dir).title == "Fresh")
    }

    @Test func createWithAZeroByteProfileYAMLWritesFromEmpty() throws {
        let (service, root) = try makeService()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let path = root + "/profiles/empty-yaml/profile.yaml"
        try write("", to: path)

        var id = service.identity(forProfile: "empty-yaml")
        id.isBotManaged = true
        id.title = "Fresh"
        // An EMPTY file is not a degraded file — there is nothing to lose by
        // merging into it.
        try service.saveIdentity(id)
        #expect(HermesBotProfileYAML.parse(
            try String(contentsOfFile: path, encoding: .utf8),
            profileName: "empty-yaml", profileDirectory: "/x"
        ).title == "Fresh")
    }

    // MARK: - The refusals must survive the fix

    @Test func aBareKeyWithANestedBodyIsStillRefused() {
        // `description:` with no inline value and a mapping under it is a
        // genuine block body, NOT a wrapped scalar — still ambiguous.
        let yaml = """
        description:
          nested: mapping
        description_auto: false

        """
        var id = HermesBotProfileYAML.parse(yaml, profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        id.title = "T"
        #expect(HermesBotProfileYAML.write(identity: id, into: yaml) == nil)
    }

    @Test func aDuplicateTopLevelScalarIsStillRefused() {
        let yaml = """
        description: one
        description: two

        """
        var id = HermesBotProfileYAML.parse(yaml, profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        id.title = "T"
        #expect(HermesBotProfileYAML.write(identity: id, into: yaml) == nil)
        // …and the LAST one is what the reader reports, as PyYAML does.
        #expect(id.profileDescription == "two")
    }

    @Test func aPopulatedInlineUIMetaIsStillRefused() {
        let yaml = "ui_meta: {a: 1}\n"
        var id = HermesBotProfileYAML.parse(yaml, profileName: "p", profileDirectory: "/x")
        id.isBotManaged = true
        id.title = "T"
        #expect(HermesBotProfileYAML.write(identity: id, into: yaml) == nil)
    }

    @Test func aBlockScalarDescriptionRoundTrips() {
        // `|` and `>` are scalars too — a value, not a body.
        let literal = "description: |\n  line one\n  line two\ndescription_auto: false\n"
        #expect(
            HermesBotProfileYAML.parse(literal, profileName: "p", profileDirectory: "/x")
                .profileDescription == "line one\nline two"
        )
        let folded = "description: >\n  line one\n  line two\ndescription_auto: false\n"
        #expect(
            HermesBotProfileYAML.parse(folded, profileName: "p", profileDirectory: "/x")
                .profileDescription == "line one line two"
        )
    }
}

/// The same 80-column wrap, one level down: the gateway persists the
/// `ui_meta` → `hermes-bots` block through `yaml.safe_dump` as well, so a bot
/// description long enough to wrap arrived truncated at the wrap point and
/// its tail was re-emitted as bogus sibling keys on the next save.
@Suite struct BotModeFoldedBotBlockTests {

    /// GENERATED, not hand-typed: this is verbatim
    /// `yaml.safe_dump(doc, default_flow_style=False, sort_keys=False,
    /// allow_unicode=True)` — the option set Hermes' `atomic_yaml_write` uses.
    static let dumped = """
    description: You are an SEO analyst that will keep an eye on a website (https://shabubox.com)
      as well as search terms that are used to find or potentially find the site through
      search, and make recommendations on changes, additions, etc for the site.
    description_auto: false
    ui_meta:
      hermes-bots:
        title: SEO Research Bot
        description: You are an SEO analyst that will keep an eye on a website (https://shabubox.com)
          as well as search terms that are used to find or potentially find the site through
          search, and make recommendations on changes, additions, etc for the site.
        color: blue
        groups:
        - research
        - seo

    """

    /// The value PyYAML's own `safe_load` returns for both description keys.
    static let role =
        "You are an SEO analyst that will keep an eye on a website (https://shabubox.com) "
        + "as well as search terms that are used to find or potentially find the site through "
        + "search, and make recommendations on changes, additions, etc for the site."

    @Test func aWrappedBotDescriptionIsReadWhole() {
        let id = HermesBotProfileYAML.parse(Self.dumped, profileName: "seo-research-bot", profileDirectory: "/x")
        #expect(id.isBotManaged)
        #expect(id.title == "SEO Research Bot")
        #expect(id.botDescription == Self.role)
        #expect(id.profileDescription == Self.role)
        #expect(id.color == "blue")
        #expect(id.groups == ["research", "seo"])
        // The wrap tail must NOT have been swept into the verbatim bucket —
        // that is what re-emitted it as junk sibling keys.
        #expect(id.unknownMetaLines.isEmpty)
    }

    @Test func rewritingAWrappedBotBlockPreservesEveryValue() throws {
        let id = HermesBotProfileYAML.parse(Self.dumped, profileName: "seo-research-bot", profileDirectory: "/x")
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: Self.dumped))
        let round = HermesBotProfileYAML.parse(out, profileName: "seo-research-bot", profileDirectory: "/x")
        #expect(round.botDescription == Self.role)
        #expect(round.profileDescription == Self.role)
        #expect(round.title == "SEO Research Bot")
        #expect(round.color == "blue")
        #expect(round.groups == ["research", "seo"])
        #expect(round.unknownMetaLines.isEmpty)
        // Idempotent: a second save changes nothing further.
        let again = try #require(HermesBotProfileYAML.write(identity: round, into: out))
        #expect(again == out)
    }

    @Test func aWrappedUnknownKeyRidesAlongWhole() throws {
        let yaml = """
        ui_meta:
          hermes-bots:
            title: T
            futureKey: some very long unmodeled value that pyyaml wrapped across
              two separate lines here

        """
        let id = HermesBotProfileYAML.parse(yaml, profileName: "p", profileDirectory: "/x")
        let out = try #require(HermesBotProfileYAML.write(identity: id, into: yaml))
        #expect(out.contains("futureKey:"))
        #expect(out.contains("two separate lines here"))
    }
}
