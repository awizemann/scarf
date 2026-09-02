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
        "Google Chat",
        "Hermes",
        "Kanban",
        "MCP",
        "Meta for Developers",
        "Microsoft Teams",
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
