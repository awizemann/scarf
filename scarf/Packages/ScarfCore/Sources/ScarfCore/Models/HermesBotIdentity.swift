import Foundation

/// A Hermes profile's Bot Mode identity, as persisted in
/// `<profile_dir>/profile.yaml`.
///
/// **A bot IS a profile.** Bot Mode adds no store of its own: the desktop
/// plugin writes presentation metadata into the profile's `profile.yaml`
/// under `ui_meta['hermes-bots']`, alongside the two top-level keys Hermes'
/// own CLI already owns (`display_name`, `description`). A profile is
/// "bot-managed" precisely when that block is a mapping — the same test
/// `tools/bot_mode_probe.py:60-76` (`_is_bot_managed`) applies before it
/// injects the Bot Chat protocol section.
///
/// **Field set.** The typed fields mirror `BotMeta` in the desktop plugin's
/// `apps/desktop/src/plugins/hermes-bots/types.ts` — every field optional,
/// because a roster row can be produced by three different code paths and
/// older gateways omit whole keys. Two deliberate omissions:
///
/// - `image` (a data URL) is **not** modeled. The desktop strips it before
///   `profiles.configure` and ships the bytes through `profiles.set_asset`
///   instead (`tui_gateway/methods_profiles.py:1020+`), so a real installation
///   keeps its avatar in `assets/avatar.{png,jpg,webp}`, not in the YAML.
///   Where a hand-written file does carry one, it survives verbatim in
///   ``unknownMetaLines`` rather than being re-quoted by Scarf's emitter — a
///   multi-kilobyte base64 scalar is exactly the value you least want a
///   line-oriented writer to reformat.
/// - Bot Mode's group *rooms* are out of scope for Phase A, but `groups` /
///   the legacy `group` scalar are modeled because they are pure roster
///   presentation and must round-trip untouched.
///
/// **Tolerant decode.** Anything inside the `hermes-bots` block that Scarf
/// doesn't model — a newer desktop's key, an operator's comment, a nested
/// body — is captured verbatim in ``unknownMetaLines`` and re-emitted on
/// write. Scarf is a client of somebody else's file; dropping a key it merely
/// failed to recognize would be data loss.
public struct HermesBotIdentity: Sendable, Equatable {

    // MARK: - Profile identity

    /// Canonical profile id (`"default"` for the root `~/.hermes` home).
    public var profileName: String

    /// Absolute (or remote-shell-resolvable) path to the profile directory.
    /// `<root>` for the default profile, `<root>/profiles/<name>` otherwise.
    public var profileDirectory: String

    /// `true` for the root home, which Hermes treats as the profile named
    /// `"default"` and which `bot_mode_probe._roster` includes in the roster.
    public var isDefaultProfile: Bool { profileName == HermesProfileScope.defaultProfileName }

    // MARK: - Top-level profile.yaml keys

    /// `display_name` — presentation-only; the canonical id never changes.
    /// Hermes clears the key rather than writing an empty string
    /// (`hermes_cli/profiles.py:980-986`), and so does Scarf's writer.
    public var displayName: String

    /// `description` — the one/two-sentence role blurb the kanban decomposer
    /// routes on. Also settable via `hermes profile describe`.
    public var profileDescription: String

    /// `description_auto` — set when the description was LLM-generated.
    /// Modeled so a Scarf edit can flip it to `false` (a human wrote this
    /// one) instead of leaving a stale "auto" marker behind.
    public var descriptionIsAuto: Bool

    // MARK: - ui_meta['hermes-bots']

    /// Whether `ui_meta['hermes-bots']` is present **as a mapping**. This is
    /// the bot-managed test, mirroring `_is_bot_managed`: a bare
    /// `hermes-bots:` header with no body loads as `None` in PyYAML, fails
    /// `isinstance(..., dict)`, and is therefore NOT bot-managed. An empty
    /// flow mapping (`hermes-bots: {}`) IS.
    public var isBotManaged: Bool

    /// `title` — the display name the user gave the bot in Bot Mode.
    /// `bot_mode_probe.py:145-147` prefers it over the profile id.
    public var title: String?

    /// `description` *inside* the bot block — distinct from the top-level
    /// profile `description`, and written by a different surface.
    public var botDescription: String?

    /// `color` — free-form; the desktop stores a hex string but never
    /// validates it, so neither does Scarf.
    public var color: String?

    /// `shape` — the generative-face shape id for the non-photo avatar.
    public var shape: String?

    /// `imageKind` — `photo` when a real image is stored in `assets/`,
    /// `shape` for a generated face. Unknown spellings are preserved rather
    /// than coerced.
    public var imageKind: ImageKind?

    /// `custom` — the user has customized the avatar, so defaults stop
    /// applying.
    public var custom: Bool?

    /// `hidden` — the bot is filtered out of the desktop roster.
    public var hidden: Bool?

    /// `pinned` — the bot sorts to the top of the roster.
    public var pinned: Bool?

    /// `groups` — the modern list form.
    public var groups: [String]

    /// `group` — the legacy single-group scalar, which the desktop still
    /// projects alongside `groups`. Kept as its own field so a file written
    /// by an older desktop round-trips exactly; ``effectiveGroups`` merges
    /// the two for display.
    public var legacyGroup: String?

    /// `created` — creation timestamp in **milliseconds**. Deliberately not
    /// copied when a bot is duplicated.
    public var created: Int?

    /// Every line inside the `hermes-bots` block that Scarf does not model,
    /// dedented to the block's own indent and preserved verbatim (keys,
    /// their nested bodies, and comments). Re-emitted after the modeled keys
    /// on write.
    public var unknownMetaLines: [String]

    // MARK: - Derived

    /// The groups this bot belongs to, merging the legacy scalar into the
    /// list form without duplicating. Order: `groups` first (the modern
    /// source of truth), then the legacy scalar if it isn't already there.
    public var effectiveGroups: [String] {
        var out = groups
        if let legacyGroup, !legacyGroup.isEmpty, !out.contains(legacyGroup) {
            out.append(legacyGroup)
        }
        return out
    }

    /// What a roster row should show: the bot's own title, else the
    /// profile's display name, else the canonical id. Mirrors
    /// `bot_mode_probe.py:129-147` (title wins) and
    /// `hermes_cli/profiles.format_profile_label` (display name over id).
    public var resolvedTitle: String {
        if let title, !title.isEmpty { return title }
        if !displayName.isEmpty { return displayName }
        return profileName
    }

    /// The blurb a roster row should show: the bot block's description when
    /// Bot Mode wrote one, else the profile-level description.
    public var resolvedDescription: String {
        if let botDescription, !botDescription.isEmpty { return botDescription }
        return profileDescription
    }

    // MARK: - Nested types

    /// `imageKind`. `.other` keeps an unrecognized spelling intact so a
    /// value written by a newer desktop survives a Scarf round-trip.
    public enum ImageKind: Sendable, Equatable {
        case photo
        case shape
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "photo": self = .photo
            case "shape": self = .shape
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .photo: return "photo"
            case .shape: return "shape"
            case .other(let raw): return raw
            }
        }
    }

    // MARK: - Init

    public init(
        profileName: String,
        profileDirectory: String,
        displayName: String = "",
        profileDescription: String = "",
        descriptionIsAuto: Bool = false,
        isBotManaged: Bool = false,
        title: String? = nil,
        botDescription: String? = nil,
        color: String? = nil,
        shape: String? = nil,
        imageKind: ImageKind? = nil,
        custom: Bool? = nil,
        hidden: Bool? = nil,
        pinned: Bool? = nil,
        groups: [String] = [],
        legacyGroup: String? = nil,
        created: Int? = nil,
        unknownMetaLines: [String] = []
    ) {
        self.profileName = profileName
        self.profileDirectory = profileDirectory
        self.displayName = displayName
        self.profileDescription = profileDescription
        self.descriptionIsAuto = descriptionIsAuto
        self.isBotManaged = isBotManaged
        self.title = title
        self.botDescription = botDescription
        self.color = color
        self.shape = shape
        self.imageKind = imageKind
        self.custom = custom
        self.hidden = hidden
        self.pinned = pinned
        self.groups = groups
        self.legacyGroup = legacyGroup
        self.created = created
        self.unknownMetaLines = unknownMetaLines
    }
}

/// A profile's avatar bytes, read from `<profile_dir>/assets/avatar.<ext>`.
///
/// The gateway writes exactly one canonical file per asset and clears the
/// other extensions first (`methods_profiles.py` `set_asset`), so a well-formed
/// profile has at most one. ``HermesBotAvatar/probeOrder`` mirrors the
/// gateway's own `{"png": …, "jpg": …, "webp": …}` iteration order so Scarf
/// picks the same file the gateway would, in the pathological case where a
/// hand-edited profile has several.
public struct HermesBotAvatar: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let path: String

    public init(data: Data, mimeType: String, path: String) {
        self.data = data
        self.mimeType = mimeType
        self.path = path
    }

    /// `(extension, mime)` in the gateway's own probe order.
    public static let probeOrder: [(ext: String, mime: String)] = [
        ("png", "image/png"),
        ("jpg", "image/jpeg"),
        ("webp", "image/webp"),
    ]

    /// Hard ceiling on an avatar read, mirroring the gateway's own
    /// `set_asset` guard (`len(blob) > 2_000_000` → error 4069). Anything
    /// larger than this could not have been written through Hermes, so
    /// Scarf refuses to pull it over a possibly-SSH transport rather than
    /// streaming an unbounded file into memory.
    public static let maxBytes = 2_000_000
}
