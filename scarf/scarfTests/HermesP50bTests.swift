import Foundation
import Testing
@testable import scarf

// MARK: - P50b: the review of P50's two commits

/// P50's `preRunScriptDowngrades` counter shipped a `String(localized:)` with
/// no row in `Localizable.xcstrings` — invisible to every existing gate,
/// because `LocalizationCatalogTests` only proves the catalogue is internally
/// consistent and `CatalogueCoverageP47Tests` only checks a hand-listed set.
/// The general gate is `t-3bcd1d7f`; this is the FILE-scoped version of it for
/// the file the review found the hole in, so the next counter added beside the
/// other four cannot ship unlocalized.
///
/// Inference, and why it matters: P50's scan of the `.help(…)` backlog mapped
/// every `\(x)` to `%@` and so declared nine already-catalogued keys missing.
/// An `Int` interpolation is `%lld`, a `String` is `%@`, and the source does
/// not say which — so a key is present when ANY assignment of the two
/// specifiers over its interpolations is in the catalogue.
@Suite("P50b · every localized literal in FleetApplyExecutor has a catalogue row")
struct FleetApplyExecutorCatalogueP50bTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    /// Every `String(localized: "…")` literal in a Swift source, with each
    /// `\(…)` collapsed to a `\(…)` marker. Interpolation-aware (so a nested
    /// `"…"` inside `\(x ?? "")` does not end the literal) and escape-aware.
    static func localizedLiterals(in source: String) -> [String] {
        let token = "String(localized: \""
        let chars = Array(source)
        var out: [String] = []
        var i = 0
        let tokenChars = Array(token)
        while i + tokenChars.count <= chars.count {
            guard Array(chars[i..<(i + tokenChars.count)]) == tokenChars else {
                i += 1
                continue
            }
            var k = i + tokenChars.count
            var depth = 0
            var buf = ""
            var closed = false
            while k < chars.count {
                let c = chars[k]
                if depth == 0, c == "\\", k + 1 < chars.count, chars[k + 1] == "(" {
                    depth = 1
                    buf += "\u{1}"   // the interpolation marker
                    k += 2
                    continue
                }
                if depth == 0, c == "\\", k + 1 < chars.count {
                    buf.append(chars[k + 1])   // \" and \\ — the escaped character itself
                    k += 2
                    continue
                }
                if depth > 0 {
                    if c == "(" { depth += 1 }
                    if c == ")" {
                        depth -= 1
                        if depth == 0 { k += 1; continue }
                    }
                    k += 1
                    continue
                }
                if c == "\"" { closed = true; break }
                buf.append(c)
                k += 1
            }
            if closed { out.append(buf) }
            i = max(k, i + 1)
        }
        return out
    }

    /// Every catalogue key the literal could spell, over `%lld`/`%@`.
    static func candidateKeys(for literal: String) -> [String] {
        let parts = literal.components(separatedBy: "\u{1}")
        let holes = parts.count - 1
        guard holes > 0 else { return [literal] }
        guard holes <= 6 else { return [] }
        var keys: [String] = []
        for mask in 0..<(1 << holes) {
            var key = parts[0]
            for h in 0..<holes {
                key += (mask & (1 << h)) == 0 ? "%lld" : "%@"
                key += parts[h + 1]
            }
            keys.append(key)
        }
        return keys
    }

    private static func catalogueKeys() throws -> Set<String> {
        let url = repoRoot.appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let root = try #require(json as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        return Set(strings.keys)
    }

    @Test func everyFleetApplyExecutorLiteralIsInTheCatalogue() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "scarf/scarf/Features/Projects/ViewModels/FleetApplyExecutor.swift"),
            encoding: .utf8)
        let literals = Set(Self.localizedLiterals(in: source))
        // Calibration: the scan must actually be finding them (round-5
        // lesson — a filter that matches nothing still reports success).
        #expect(literals.count >= 15,
                "the scan found \(literals.count) literals — it stopped matching")
        let keys = try Self.catalogueKeys()
        var missing: [String] = []
        for literal in literals.sorted() {
            let candidates = Self.candidateKeys(for: literal)
            if candidates.first(where: { keys.contains($0) }) == nil {
                missing.append(literal.replacingOccurrences(of: "\u{1}", with: "\\(…)"))
            }
        }
        #expect(missing.isEmpty, "FleetApplyExecutor literals with no catalogue row: \(missing)")
    }

    /// The specific row P50 shipped without, in all six locales — the
    /// `CatalogueCoverageP47Tests` shape, so a locale dropped later is named
    /// rather than lumped into the scan above.
    @Test func theNewPreRunScriptCounterCarriesAllSixLocales() throws {
        let key = "%lld w/o their pre-run script (the file stays on this host)"
        let url = Self.repoRoot.appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = try #require((json as? [String: Any])?["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any], "\(key) has no catalogue row")
        let locs = try #require(entry["localizations"] as? [String: Any])
        for locale in ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"] {
            #expect(locs[locale] != nil, "\(key) is missing \(locale)")
        }
    }

    /// The inference itself, pinned: the sibling counters are `%lld` and the
    /// one `String` interpolation in the file is `%@`. A scan that assumed
    /// `%@` throughout would call the first four missing.
    @Test func theSpecifierInferenceFindsBothShapes() throws {
        let keys = try Self.catalogueKeys()
        #expect(keys.contains("%lld w/o run-to-run continuity"))
        #expect(keys.contains("set board %@"))
        let intish = Self.candidateKeys(for: "\u{1} failed")
        #expect(intish.contains("%lld failed"))
        #expect(intish.contains("%@ failed"))
    }
}
