import Foundation
import Testing

/// Invariants over `scarf/scarf/Localizable.xcstrings` itself.
///
/// These are cheap structural pins, not UI tests. They exist because the
/// catalog is edited by three different paths — Xcode's extractor,
/// `tools/merge-translations.py`, and hand edits — and each has silently
/// broken one of these rules before:
///
/// * A translated `%@`/`%lld` count that drifts from the English source is a
///   crash (or a garbage substitution) at runtime, not a cosmetic bug.
/// * The English stem+suffix plural hack (`"\(n) skill\(n == 1 ? "" : "s")"`
///   → key `"%lld skill%@"`) substitutes an *English* suffix into `%@`. Any
///   translation of such a key produces "3 Fähigkeits" nonsense, so these
///   keys must stay untranslated and fall back to English.
@Suite("Localizable.xcstrings invariants")
struct LocalizationCatalogTests {

    // MARK: - Loading

    /// Repo-relative path derived from this file's location, so the test
    /// reads the *source* catalog rather than whatever got copied into a
    /// build product.
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)      // …/scarf/scarfTests/ThisFile.swift
            .deletingLastPathComponent()     // …/scarf/scarfTests
            .deletingLastPathComponent()     // …/scarf
            .appendingPathComponent("scarf/Localizable.xcstrings")
    }

    struct Catalog {
        let sourceLanguage: String
        /// key → locale → (state, value)
        let strings: [String: [String: (state: String, value: String?)]]

        init(url: URL) throws {
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let root = raw as! [String: Any]
            sourceLanguage = root["sourceLanguage"] as! String
            var out: [String: [String: (state: String, value: String?)]] = [:]
            for (key, entryAny) in (root["strings"] as! [String: Any]) {
                let entry = entryAny as? [String: Any] ?? [:]
                var locales: [String: (state: String, value: String?)] = [:]
                for (locale, locAny) in (entry["localizations"] as? [String: Any] ?? [:]) {
                    guard let unit = (locAny as? [String: Any])?["stringUnit"] as? [String: Any]
                    else { continue }
                    locales[locale] = (unit["state"] as? String ?? "",
                                       unit["value"] as? String)
                }
                out[key] = locales
            }
            strings = out
        }
    }

    static let catalog: Catalog = try! Catalog(url: catalogURL)

    /// The locales the app actually ships (mirrors `LOCALES` in
    /// `tools/merge-translations.py`).
    static let shippedLocales: Set<String> = ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"]

    /// Xcode's extractor also writes an `en` column (state `new`) for some
    /// source strings. That column is the source language, not a
    /// translation, so every locale rule below skips it.
    static let sourceLocale = "en"

    /// Two plural-hack keys were translated before this rule was written and
    /// are kept deliberately (the pre-release audit board signed them off);
    /// everything else must fall back to English. Do not grow this list.
    ///
    /// F7 retired seven hack keys outright by moving their call sites to
    /// automatic grammar agreement (`^[\(n) session](inflect: true)`), which
    /// IS translatable — 18 hack keys became 11. These two stay as they are.
    static let pluralHackExceptions: Set<String> = [
        "%lld delivery failure%@",
        "Applied to %lld host%@",
    ]

    // MARK: - Helpers

    /// A key built by the English stem+suffix plural hack: a count in the
    /// same string plus a `%@` glued directly onto a word (`skill%@`,
    /// `entr%@`). `v%@` and friends are excluded by the `%lld` requirement.
    static func isEnglishPluralHack(_ key: String) -> Bool {
        guard key.contains("%lld") else { return false }
        return key.range(of: "[A-Za-z]%@", options: .regularExpression) != nil
    }

    /// True when, once the format specifiers are removed, nothing with a
    /// Latin letter remains — punctuation, separators, bare counts and
    /// glyph-only strings (`"—"`, `"%@: %@"`, `"×%lld"`). There is nothing
    /// in these to translate, so locales legitimately omit them.
    static func hasNoTranslatableWords(_ key: String) -> Bool {
        let stripped = key.replacingOccurrences(
            of: "%(?:[0-9]+\\$)?(@|lld|ld|d|f|lf)",
            with: "",
            options: .regularExpression)
        return stripped.range(of: "[A-Za-z]", options: .regularExpression) == nil
    }

    /// Multiset of conversion specifiers, with positional prefixes stripped
    /// so `%1$@` counts as `%@` — reordering for grammar is legitimate,
    /// changing the *set* of arguments is not.
    static func specifiers(_ s: String) -> [String: Int] {
        let pattern = "%(?:[0-9]+\\$)?(@|lld|ld|d|f|lf)"
        let re = try! NSRegularExpression(pattern: pattern)
        var counts: [String: Int] = [:]
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            counts[ns.substring(with: m.range(at: 1)), default: 0] += 1
        }
        return counts
    }

    // MARK: - Tests

    /// Keys whose only call sites live in the iOS target. Xcode's extractor
    /// runs from the macOS scheme and PRUNES any key it cannot see in that
    /// build, and the iOS scheme never writes back to the shared catalog —
    /// so every macOS-side extraction silently deletes these (it has done so
    /// twice: 2026-09-08, both builds). They are maintained by hand; after
    /// an extraction, restore them verbatim from git.
    static let iosOnlyKeys: [String] = [
        "%@ (%lld)",
        "%@. %@",
        "%lld file%@",
        "%lld prompt%@ queued — manage on the Mac app",
        "ScarfGo",
        "Not saved: %@",
        // P42c: added by P42b's iOS duplicate work
        // (`Scarf iOS/Cron/CronListView.swift:171`, `:329`) and registered
        // here in the same pass that found them unregistered. The audit that
        // produced this entry swept EVERY catalog key added since `5be08f2e`
        // against its call sites; these two were the only ones whose only
        // call site is under `Scarf iOS`.
        "Duplicate cron job",
        "Pick a future time — a one-shot more than %lld s in the past can never fire.",
        // P56: the edit sheet's title, the last of the three `CronEditorView`
        // titles without a row ("New cron job" has one because `CronView` on
        // the Mac uses the same literal). The other twenty-one unlocalized
        // `.help(…)` literals stay on `t-3bcd1d7f`.
        "Edit cron job",
        // t-af7b8cc4 item 3: the voice extraction pass (dictation,
        // Live Voice, consent sheets, Settings rows). Every key below
        // has its only call site under `Scarf iOS`, so a macOS-scheme
        // extraction would prune it.
        "$0.05 per minute on the host's OpenAI key",
        "Accepted %@",
        "Add `OPENAI_API_KEY=…` to `~/.hermes/.env`, or set `voice.gpt_live.api_key` in config.yaml.",
        "Another app is using the microphone. Finish there, then try again.",
        "Come back here and tap Try Again. Live Voice bills that key $0.05 per minute while a session is open.",
        "Consent",
        "Couldn't reach your Hermes host to start Live Voice.",
        "Couldn't start Live Voice audio on this device.",
        "Couldn't start recording. Try again.",
        "Couldn’t read this file: %@",
        "Detail",
        "Dictate message",
        "Dictation cancelled.",
        "Dictation isn't available in your language on this device.",
        "Dictation isn't available — speech recognition is restricted on this device.",
        "Dictation was interrupted. Try again.",
        "Elapsed %@, approximately %@, billed at 5 cents per minute on the host's OpenAI key",
        "Ends the Live Voice session.",
        "Ends the session and stops billing.",
        "Hermes couldn't start Live Voice. Try again; if it keeps failing, check the host's Hermes logs.",
        "Hermes is busy with a typed request, so Live Voice didn't interrupt it. Ask again when it's finished.",
        "Hermes is working on it…",
        "Hold to record; release to transcribe. Slide away to cancel.",
        "Last seen",
        "Live Voice (GPT-Live)",
        "Live Voice Privacy",
        "Live Voice ended",
        "Live Voice ended because another app or a call took the audio.",
        "Live Voice ended because the connection to Hermes was lost.",
        "Live Voice ended because the connection to Hermes was lost. Your spoken turns and Hermes's replies so far are in the chat.",
        "Live Voice ended on its own after %lld minutes with no speech, so it stopped billing.",
        "Live Voice ended on its own after Hermes waited 10 minutes with no speech, so it stopped billing. The request is still in the chat.",
        "Live Voice ended. Your spoken turns and Hermes's replies are in the chat.",
        "Live Voice is a spoken, back-and-forth conversation with Hermes from the Chat tab. Your voice streams directly from this device to OpenAI; the Hermes host only sets up the session, so OpenAI also sees this device's network address, and each session shares recent chat messages for context. It needs an OpenAI API key on the Hermes host (OPENAI_API_KEY, or voice.gpt_live.api_key) and bills that key about $0.05 per minute while a session is open. This mode is a Hermes setting for the whole profile: it also switches voice in Hermes's own apps.",
        "Live Voice needs an OpenAI API key on your Hermes host. Nothing was charged.",
        "Live Voice needs setup",
        "Live Voice stopped",
        "Microphone access is off. Enable it in Settings to dictate.",
        "Microphone access is off. Enable it in Settings to use Live Voice.",
        "Microphone muted",
        "Mute",
        "Not accepted",
        "Nothing was heard. Hold the microphone button while you speak.",
        "Occurrences",
        "OpenAI refused the Live Voice session (error %lld). Check the key's access and quota on the host.",
        "OpenAI refused the Live Voice session. Check the key's access and quota on the host.",
        "Projects couldn't be read",
        "Projects registry damaged. %@",
        "Recording… slide away to cancel",
        "Recovery actions live on the Mac app — open this task there to unblock, complete, or archive it.",
        "Reset consent",
        "Returns to the chat.",
        "Review what Live Voice shares",
        "Save failed: %@",
        "Scarf couldn't find Hermes's Python on the server, so Live Voice couldn't start.",
        "ScarfGo asks before the first Live Voice session on this device. After a reset it asks again.",
        "ScarfGo asks once on this device. You can review or reset this in Settings.",
        "ScarfGo can't use the microphone. Allow microphone access in Settings, then try again.",
        "Session time %@, approximately %@.",
        "Something went wrong. %@",
        "Speak naturally. Say “stop” or tap End when you're done.",
        "Speech recognition is off. Enable it in Settings to dictate.",
        "Start dictating",
        "Starting the microphone and connecting through your Hermes host.",
        "Starts a spoken conversation with Hermes. Billed at 5 cents a minute on the host's OpenAI key.",
        "Stop dictating",
        "To set it up, on the Hermes host:",
        "Transcribing…",
        "Transcription failed. Try again.",
        "Unavailable during a Live Voice session.",
        "Unavailable until the chat is connected.",
        "Unavailable while dictating.",
        "Unmute",
        "Update Hermes on the host (`hermes update`), then try again.",
        "Voice chat mode",
        "You said stop, so Live Voice ended.",
        "Your Hermes host couldn't reach OpenAI to start Live Voice.",
        "Your voice streams directly from this device to OpenAI. The Hermes host only sets up the session, so OpenAI also sees this device's network address.",
        "Your voice streams from this device to %@, which also sees this device's network address.",
        "≈ %@",
        // P7 chained-engine pass: the iOS half of the chained voice
        // surfaces (session sheet, Settings voice rows, the composer's
        // voice button). Every key below has its only call site under
        // `Scarf iOS`, so a macOS-scheme extraction would prune it.
        "About $0.05 per minute",
        "Chained",
        "Chained is a spoken conversation from the Chat tab that costs nothing extra. Your voice is turned into words on this iPhone and never leaves it — only the words you said go to Hermes, exactly like a typed message. Replies are read aloud by the host's text-to-speech provider, which sees the reply text (Hermes's default, edge, sends it to Microsoft). This mode is a Hermes setting for the whole profile: it also switches voice in Hermes's own apps.",
        "Couldn't reach your Hermes host's voice, so replies are being read by this iPhone's system voice.",
        "Do the same under Settings › Privacy & Security › Microphone, then tap Try Again.",
        "Elapsed %@. Your voice stays on this iPhone; replies are spoken by the host's voice or the system voice.",
        "If your language has no on-device model, switch to Live Voice (GPT-Live) in Settings.",
        "On this iPhone",
        "Open Settings › General › Keyboard and turn on Dictation, so iOS downloads your language's on-device model.",
        "Open Settings › Privacy & Security › Speech Recognition and turn ScarfGo on.",
        "ScarfGo asks before the first Live Voice (GPT-Live) session on this device. After a reset it asks again. Chained mode sends no voice to anyone, so it never asks.",
        "ScarfGo can't use speech recognition, so it can't turn your voice into words on this iPhone.",
        "Session time %@. Nothing was charged.",
        "Speech to text",
        "Starts a spoken conversation with Hermes. Your voice stays on this iPhone.",
        "Text to speech",
        "This iPhone has no on-device speech recognition for your language, and ScarfGo never sends your voice away to transcribe it.",
        "Your voice stays on this iPhone; replies are spoken by the host's voice or the system voice.",
    ]

    @Test("iOS-only keys survive a macOS-scheme extraction")
    func iosOnlyKeysAreStillInTheCatalog() {
        for key in Self.iosOnlyKeys {
            #expect(
                Self.catalog.strings[key] != nil,
                "\(key) is gone — Xcode's macOS extraction pruned it again; restore it from git (see this list's doc comment)"
            )
        }
    }

    @Test("catalog parses and is English-sourced")
    func catalogLoads() {
        #expect(Self.catalog.sourceLanguage == "en")
        #expect(Self.catalog.strings.count > 2000)
    }

    @Test("English plural-hack keys are never translated")
    func pluralHackKeysStayEnglish() {
        let offenders = Self.catalog.strings
            .filter { key, locales in
                guard Self.isEnglishPluralHack(key),
                      !Self.pluralHackExceptions.contains(key) else { return false }
                return !locales.keys.filter { $0 != Self.sourceLocale }.isEmpty
            }
            .map { "\($0.key) → \($0.value.keys.sorted().joined(separator: ","))" }
            .sorted()
        #expect(offenders.isEmpty, "plural-hack keys must fall back to English: \(offenders)")
    }

    @Test("the plural-hack set is still recognised")
    func pluralHackSetIsNonEmpty() {
        // Guards the detector itself: if a refactor removed every hack key
        // the test above would pass vacuously.
        let hacks = Self.catalog.strings.keys.filter(Self.isEnglishPluralHack)
        #expect(hacks.count >= 10)
    }

    @Test("every translation matches its source's format specifiers")
    func specifierParity() {
        var offenders: [String] = []
        for (key, locales) in Self.catalog.strings {
            let expected = Self.specifiers(key)
            for (locale, unit) in locales {
                guard let value = unit.value else { continue }
                let got = Self.specifiers(value)
                if got != expected {
                    offenders.append("[\(locale)] \(key) → \(value) (\(expected) vs \(got))")
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "specifier drift:\n" + offenders.sorted().joined(separator: "\n")))
    }

    @Test("every localization is marked translated")
    func allLocalizationsAreTranslated() {
        var offenders: [String] = []
        for (key, locales) in Self.catalog.strings {
            for (locale, unit) in locales
            where locale != Self.sourceLocale && unit.state != "translated" {
                offenders.append("[\(locale)] \(key): state=\(unit.state)")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "non-translated states:\n" + offenders.sorted().joined(separator: "\n")))
    }

    @Test("no unexpected locale columns")
    func onlyShippedLocales() {
        let seen = Set(Self.catalog.strings.values.flatMap(\.keys))
        #expect(seen.subtracting(Self.shippedLocales).subtracting([Self.sourceLocale]).isEmpty)
    }

    @Test("translations are non-empty")
    func noEmptyTranslations() {
        let offenders = Self.catalog.strings.flatMap { key, locales in
            locales.compactMap { locale, unit -> String? in
                guard locale != Self.sourceLocale,
                      let v = unit.value, v.isEmpty, !key.isEmpty else { return nil }
                return "[\(locale)] \(key)"
            }
        }
        #expect(offenders.isEmpty, "empty translations: \(offenders.sorted())")
    }

    /// Source strings that deliberately fall back to English in every locale
    /// that omits them: proper nouns and product names (Docker, OAuth,
    /// SOUL.md), CLI/config literals the user must type verbatim
    /// (`npx`, `oauth`, `supports_parallel_tool_calls`), sample values and
    /// URL placeholders, and bare acronyms.
    ///
    /// This is the documented exception list for `everyTranslatableKeyIsLocalized`
    /// below. Adding a key here is a decision that the string is *not* prose —
    /// if it is prose, translate it instead.
    static let englishFallbackKeys: Set<String> = [
        "#C1502E",
        "/path/to/client.key",
        "/path/to/client.pem",
        "/path/to/project",
        "Bitwarden Secrets Manager",
        "CLI",
        "Camofox",
        "Daytona",
        "Docker",
        "GPT-Live",
        "Google Chat",
        "Hermes",
        "Hermes Voice",
        "Kanban",
        "Live Voice",
        "Live Voice (GPT-Live)",
        "MCP",
        "Meta for Developers",
        "Microsoft Teams",
        "Nous Portal",
        "OAuth",
        "OAuth 2.1",
        "OpenRouter",
        "SOUL.md",
        "Scarf",
        "ScarfGo",
        "Singularity",
        "URL",
        "Webhook",
        "X",
        "X-User-Id",
        "Y",
        "YOLO",
        "Yuanbao 元宝",
        "acme-q3",
        "alice",
        "discord",
        "hermes peer add spark --url http://spark.lan:8377 --key <API_SERVER_KEY>",
        "hermes profile show",
        "https://...",
        "https://.../sse",
        "https://example.com/my.scarftemplate",
        "https://example.com/path/to/SKILL.md",
        "https://…",
        "local-only",
        "markdown",
        "my_server",
        "new-name",
        "npx",
        "oauth",
        "owner/name",
        "p%lld",
        "p50 %@",
        "p95 %@",
        "research-bot",
        "scarf-default",
        "sk-…",
        "stderr:",
        "stdout:",
        "supports_parallel_tool_calls",
        "tool-override",
        "tool_a, tool_b",
        "tool_c",
        "v%@",
        "~/Projects",
    ]

    /// Every key that is real UI prose carries all six locales.
    ///
    /// The catalog is allowed three kinds of hole, and only three: the English
    /// stem+suffix plural hack, strings with no translatable words at all
    /// (pure format specifiers and punctuation), and the explicitly listed
    /// `englishFallbackKeys`. Anything else missing a locale is a gap —
    /// this is what kept regressing when new features shipped between
    /// Xcode-side extractions.
    @Test("every translatable key is localized in all six locales")
    func everyTranslatableKeyIsLocalized() {
        var offenders: [String] = []
        for (key, locales) in Self.catalog.strings {
            guard !Self.isEnglishPluralHack(key),
                  !Self.hasNoTranslatableWords(key),
                  !Self.englishFallbackKeys.contains(key) else { continue }
            let missing = Self.shippedLocales.subtracting(locales.keys).sorted()
            if !missing.isEmpty {
                offenders.append("\(key) → missing \(missing.joined(separator: ","))")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "untranslated keys:\n" + offenders.sorted().joined(separator: "\n")))
    }

    /// Guards the exception list against rot: a fallback key that has since
    /// been fully translated (or removed from the catalog) should leave the
    /// list rather than sit there hiding a future gap.
    @Test("the English-fallback list has no stale entries")
    func fallbackListIsCurrent() {
        var stale: [String] = []
        for key in Self.englishFallbackKeys {
            guard let locales = Self.catalog.strings[key] else {
                stale.append("\(key): not in catalog"); continue
            }
            if Self.shippedLocales.subtracting(locales.keys).isEmpty {
                stale.append("\(key): fully translated, drop it from the list")
            }
        }
        #expect(stale.isEmpty, Comment(rawValue: "stale fallback entries:\n" + stale.sorted().joined(separator: "\n")))
    }
}

// MARK: - F7: component-parameter recovery

/// Section-audit fix package F7 converted `String`-typed display parameters on
/// shared components to `LocalizedStringKey`. A `String` binds `Text`'s
/// VERBATIM overload, so those call sites were never extracted — and several of
/// their keys were *already sitting translated in the catalog*, reachable only
/// through a code path that no longer existed. The conversion is what makes
/// them reachable again; the runtime lookup itself is `Text`'s job, so what a
/// test can pin is that the key the converted call site now passes still exists
/// in the catalog, translated, under exactly that spelling.
///
/// A rename or a re-worded literal at any of these call sites breaks this test
/// rather than silently going back to English.
@Suite("F7 localization recovery")
struct LocalizationF7RecoveryTests {

    /// Keys whose call sites were dead before F7, sampled across the packages
    /// the fix touched. Spelling here must match the source literal EXACTLY.
    static let recoveredKeys: [String] = [
        "Overview",                                        // InsightsView.sectionHeader
        "Top Tools",                                       // InsightsView.sectionHeader
        "Unknown widget type: \"%@\"",                     // WidgetErrorCard.reason
        "0 9 * * *  or  30m  or  every 2h",                // CronJobEditor placeholder
        "Edit %@",                                         // CronJobEditor.headerText
        "Loading cron jobs…",                              // loadingOverlay(label:)
        "No site widget in this project's dashboard.",     // CockpitEmptyState.text
        "Journal Mode",                                    // PickerRow.label
        "Max Turns",                                       // StepperRow.label
        "Mount CWD",                                       // ToggleRow.label
        "Pinned, then name",                               // BotRosterSort.label
        "Recently updated",                                // Kanban sortOptions
        "Today",                                           // SessionsViewModel.QuickFilter
        "Allowed channels",                                // GatewayAllowlistKind vocabulary
        "Send prompts to this chat's agent",               // MiniAppPermission consent sheet
        "Path must be relative to the project root, not absolute.",  // WidgetPathResolver
        "server not registered on this Mac",               // FleetApplyExecutor.FieldResult
    ]

    @Test("every key recovered by the LocalizedStringKey conversion is in the catalog")
    func recoveredKeysArePresent() {
        let catalog = LocalizationCatalogTests.catalog
        let absent = Self.recoveredKeys.filter { catalog.strings[$0] == nil }
        #expect(absent.isEmpty, Comment(rawValue: "unreachable keys:\n" + absent.joined(separator: "\n")))
    }

    @Test("every recovered key carries all six locales")
    func recoveredKeysAreTranslated() {
        let catalog = LocalizationCatalogTests.catalog
        var offenders: [String] = []
        for key in Self.recoveredKeys {
            guard let locales = catalog.strings[key] else { continue }
            let missing = LocalizationCatalogTests.shippedLocales.subtracting(locales.keys).sorted()
            if !missing.isEmpty { offenders.append("\(key) → missing \(missing.joined(separator: ","))") }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "partly-translated recovered keys:\n" + offenders.sorted().joined(separator: "\n")))
    }

    /// The seven plural-hack keys F7 retired must be GONE, not merely unused:
    /// a stale key sits in the catalog looking translated while the live call
    /// site renders the new inflected one.
    @Test("retired plural-hack keys are removed from the catalog")
    func retiredPluralHacksAreGone() {
        let catalog = LocalizationCatalogTests.catalog
        let retired = [
            "%lld health issue%@",
            "%lld incident%@",
            "Health check found %lld issue%@",
            "Showing %lld session%@ from",
            "Rewound %lld time%@",
            "Rewound %lld time%@ (Hermes v0.16+)",
            "Hermes auto-compacted this session's context %lld time%@",
        ]
        let lingering = retired.filter { catalog.strings[$0] != nil }
        #expect(lingering.isEmpty, Comment(rawValue: "stale hack keys:\n" + lingering.joined(separator: "\n")))
    }

    /// Their inflected replacements must exist and be translated — otherwise
    /// the retirement above just deleted six languages' worth of copy.
    @Test("the inflected replacements exist and are translated")
    func inflectedReplacementsAreTranslated() {
        let catalog = LocalizationCatalogTests.catalog
        let replacements = [
            "^[%lld health issue](inflect: true)",
            "^[%lld incident](inflect: true)",
            "Health check found ^[%lld issue](inflect: true)",
            "Showing ^[%lld session](inflect: true) from",
            "Rewound ^[%lld time](inflect: true)",
            "Rewound ^[%lld time](inflect: true) (Hermes v0.16+)",
            "Hermes auto-compacted this session's context ^[%lld time](inflect: true)",
        ]
        var offenders: [String] = []
        for key in replacements {
            guard let locales = catalog.strings[key] else {
                offenders.append("\(key): not in catalog"); continue
            }
            let missing = LocalizationCatalogTests.shippedLocales.subtracting(locales.keys).sorted()
            if !missing.isEmpty { offenders.append("\(key) → missing \(missing.joined(separator: ","))") }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.sorted().joined(separator: "\n")))
    }

    // MARK: - P60: a catalogue row a call site cannot reach

    /// **A row in six locales is worth nothing if the call site's TYPE picks
    /// the verbatim overload.**
    ///
    /// `CronEditorView.init(title:)` took a `String` and fed it to
    /// `.navigationTitle(title)`, which has a `StringProtocol` overload that
    /// renders its argument verbatim. All three titles — "Edit cron job",
    /// "New cron job", "Duplicate cron job" — already had rows in all six
    /// shipped locales (two of them hand-maintained in ``iosOnlyKeys`` for
    /// exactly this sheet), and not one of them ever resolved.
    ///
    /// This asserts the SPELLING at the call site, not the behaviour: the
    /// parameter is a `LocalizedStringResource`, which makes each literal a
    /// resource literal, and the title goes through `Text(title)`, which has
    /// no verbatim overload to fall into. A behavioural test cannot see this
    /// — the wrong overload renders the English string, which is what the
    /// test's own locale expects.
    @Test("the iOS cron editor's title resolves through the catalogue")
    func cronEditorTitleIsALocalizedResource() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // …/scarf/scarfTests
                .deletingLastPathComponent()   // …/scarf
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("scarf/Scarf iOS/Cron/CronListView.swift"),
            encoding: .utf8)

        #expect(source.contains("let title: LocalizedStringResource"), """
            `CronEditorView.title` is a `String` again — `.navigationTitle` \
            takes the `StringProtocol` overload and renders it verbatim, so \
            the three catalogue rows below are unreachable.
            """)
        #expect(source.contains("title: LocalizedStringResource,"),
                "the initialiser's parameter type drifted from the stored property's")
        #expect(source.contains(".navigationTitle(Text(title))"), """
            the title no longer goes through `Text`, which is the one \
            spelling with no verbatim overload to fall into
            """)
        #expect(!source.contains("title: String"),
                "a `String` title parameter is back on this view")

        // The three spellings the call sites pass, and their rows. The keys
        // are read FROM the source rather than typed here, so a renamed
        // title cannot leave this test asserting a string nobody passes
        // (round-6 lesson 6, and the P54b hand-maintained-list gotcha).
        let pattern = try NSRegularExpression(pattern: #"title: "([^"]+)""#)
        let ns = source as NSString
        let titles = pattern
            .matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        #expect(Set(titles) == ["Edit cron job", "New cron job", "Duplicate cron job"],
                "the CronEditorView call sites' titles changed: \(Set(titles).sorted())")

        let catalog = LocalizationCatalogTests.catalog
        var offenders: [String] = []
        for key in Set(titles) {
            guard let locales = catalog.strings[key] else {
                offenders.append("\(key): not in catalog"); continue
            }
            let missing = LocalizationCatalogTests.shippedLocales
                .subtracting(locales.keys).sorted()
            if !missing.isEmpty {
                offenders.append("\(key) → missing \(missing.joined(separator: ","))")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.sorted().joined(separator: "\n")))
    }
}
