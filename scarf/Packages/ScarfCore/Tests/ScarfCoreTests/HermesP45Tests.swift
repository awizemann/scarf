import Foundation
import Testing
@testable import ScarfCore

// MARK: - P45 finding 4: the plugins-update disable line is a SHAPE

/// `pluginsUpdateSecurityDisabled` was matched as the bare substring
/// `has been disabled.` over output Hermes does not author: `cmd_update`
/// echoes the raw `git pull` body (`plugins_cmd.py:829`) and
/// `_rescan_after_update` prints the scan report (`:844`). The line Hermes
/// actually writes is `Plugin '<name>' has been disabled. Review the
/// findings, …` (`:848-851`), so the match is now anchored on the column-0
/// `Plugin ` prefix — the same shape as `isSuccessLine`.
@Suite("P45 · plugins update security-disable shape")
struct PluginsUpdateDisableShapeP45Tests {

    /// A pulled commit message is quoted verbatim into the success output.
    /// Before the fix this turned an ordinary update into "Updated, then
    /// disabled by the security scan."
    @Test func aGitPullEchoIsNotADisableLine() {
        let output = """
        Updating 1a2b3c4..5d6e7f8
        Fast-forward
         README.md | 2 +-
         1 file changed
        chore: the legacy telemetry hook has been disabled.
        ✓ Plugin acme updated.
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil,
                "a git-pull echo was read as Hermes's own disable line: \(outcome.warning ?? "nil")")
    }

    /// …and the scan report's own findings are quoted the same way.
    @Test func aScanReportFindingIsNotADisableLine() {
        let output = """
        ⚠ Security scan flagged the updated plugin: 1 finding
        finding: the sandbox has been disabled.
        ✓ Plugin acme updated.
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        let warning = outcome.warning ?? ""
        #expect(warning.contains("flagged"),
                "the flagged line still owes a warning: \(warning)")
        #expect(!warning.contains("disabled by the security scan"),
                "a scan finding was read as the disable line: \(warning)")
    }

    /// The real line, at column 0 and with the sentence that follows it.
    @Test func hermesOwnDisableLineIsStillMatched() {
        let output = """
        ⚠ Security scan flagged the updated plugin: dangerous
        Plugin 'acme' has been disabled. Review the findings, then re-enable
        with `hermes plugins enable acme` if you trust them.
        ✓ Plugin acme updated.
        """
        let outcome = HermesPluginsUpdateVerdict.judge(output: output, exitCode: 0)
        #expect(outcome.succeeded)
        #expect(outcome.warning?.contains("disabled by the security scan") == true,
                "the dangerous verdict lost its wording: \(outcome.warning ?? "nil")")
    }

    /// The shape predicate itself, both halves.
    @Test func theShapeNeedsBothThePrefixAndTheClause() {
        #expect(HermesPluginsUpdateVerdict.isSecurityDisableLine(
            "Plugin 'acme' has been disabled. Review the findings."))
        #expect(!HermesPluginsUpdateVerdict.isSecurityDisableLine(
            "chore: the legacy hook has been disabled."))
        #expect(!HermesPluginsUpdateVerdict.isSecurityDisableLine("Plugin 'acme' updated."))
    }
}

// MARK: - P45 finding 5: the stored effort is compared the way Hermes compares it

/// `parse_reasoning_effort` runs `str(effort).strip().lower()` before it
/// compares — `hermes_constants.py:884` @ `v2026.9.7`, `:807` @ `v2026.7.1`.
/// Scarf compared the RAW stored value, so `Max` widened the picker to a
/// duplicate row beside `max` and `" high "` drew an "isn't supported"
/// notice for a value the host accepts.
@Suite("P45 · reasoning effort normalisation")
struct ReasoningEffortNormalisationP45Tests {

    private static let target = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")

    /// P45 asked the ROW question of the normalised form and blanked the
    /// picker: the `Picker`'s tags and selection are the RAW stored string,
    /// so `Max` with only a `max` tag renders an EMPTY control — the very
    /// failure the widening overload exists to prevent. The row is widened
    /// on RAW membership; what `Max` must not earn is the NOTICE.
    @Test func aCasedLevelKeepsATagOfItsOwn() {
        let widened = HermesReasoningEffort.levels(capabilities: Self.target, selected: "Max")
        #expect(widened.first == "Max", "`Max` has no tag and the picker renders blank: \(widened)")
        #expect(widened.dropFirst() == HermesReasoningEffort.levels(capabilities: Self.target)[...])
    }

    @Test func aPaddedLevelKeepsATagOfItsOwn() {
        let widened = HermesReasoningEffort.levels(capabilities: Self.target, selected: " high ")
        #expect(widened.first == " high ", "` high ` has no tag and the picker renders blank: \(widened)")
    }

    /// A whitespace-only value is `str(effort).strip()` == "" to Hermes
    /// (`hermes_constants.py:884` @ `v2026.9.7`) — the absent-key case. It is
    /// the "Hermes default" sentinel: no extra row, no notice.
    ///
    /// P46b: and therefore no raw SELECTION either. This test pinned half the
    /// contract — the options — while the binding still handed the `Picker`
    /// the raw `"   "`, which matches neither the sentinel row's `""` tag nor
    /// any level, so the control rendered blank anyway. The selection is the
    /// other half and belongs in the same test.
    @Test func aWhitespaceOnlyValueIsTheSentinel() {
        #expect(HermesReasoningEffort.levels(capabilities: Self.target, selected: "   ")
                == HermesReasoningEffort.levels(capabilities: Self.target))
        #expect(HermesReasoningEffort.unsupportedLevelNotice(for: "   ", capabilities: Self.target) == nil)
        #expect(HermesReasoningEffort.pickerSelection(for: "   ") == "",
                "the picker is handed a value no tag matches, and renders blank")
    }

    @Test func aCasedOrPaddedLevelDrawsNoUnsupportedNotice() {
        for stored in ["Max", " high ", "  ULTRA", "Medium "] {
            #expect(HermesReasoningEffort.unsupportedLevelNotice(
                for: stored, capabilities: Self.target) == nil,
                "“\(stored)” is accepted by `parse_reasoning_effort` — no notice is owed")
        }
    }

    /// A value that is genuinely out of vocabulary still widens (decision 13)
    /// and still draws the notice, in whatever case it is stored.
    @Test func aGenuinelyUnknownLevelStillWidensAndStillWarns() throws {
        let widened = HermesReasoningEffort.levels(capabilities: Self.target, selected: "Turbo")
        #expect(widened.first == "Turbo", "the stored value lost its row: \(widened)")
        let notice = try #require(HermesReasoningEffort.unsupportedLevelNotice(
            for: "Turbo", capabilities: Self.target))
        #expect(notice.contains("Turbo"), "the notice must quote what is on disk")
    }

    /// The empty sentinel widens nothing. (The whitespace-only case is
    /// `aWhitespaceOnlyValueIsTheSentinel` above: P45 gave it a row on the
    /// theory that a `Picker` needs a tag, but `str(effort).strip()` makes
    /// it Hermes's absent-key case, so the sentinel row is the honest one.)
    @Test func theEmptyStringWidensNothing() {
        #expect(HermesReasoningEffort.levels(capabilities: Self.target, selected: "")
            == HermesReasoningEffort.levels(capabilities: Self.target))
    }

    /// The widened row displays the RAW string — that is what config.yaml
    /// holds, and the picker has to match it to select it.
    @Test func theWidenedRowKeepsTheRawSpelling() {
        #expect(HermesReasoningEffort.levels(capabilities: Self.target, selected: "  Turbo ")
            .first == "  Turbo ")
    }
}

// MARK: - P45 finding 9: an anchored marker list is only ever used anchored

/// Six failure lists are spelled as if unanchored (`configSetFailure`,
/// `configUnsetFailure`, `skillsTrustFailure`, `memoryOffFailure`,
/// `mcpRemoveFailure`) while `gatewayServiceFailureAnchored` says so in its
/// name. Renaming them would invalidate forty commits of audit docs that
/// cite the current names, so the invariant is enforced here instead: a list
/// built on ``HermesCLIMarkers/managedRefusalAnchored`` carries column-0
/// refusals, and passing one at the unanchored `failureMarkers:` label would
/// let a quoted refusal anywhere in a line fail a successful run.
@Suite("P45 · anchored marker lists stay anchored")
struct AnchoredMarkerUseP45Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ScarfCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/ScarfCore
            .deletingLastPathComponent()   // …/Packages
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    private static let scanRoots = [
        "scarf/scarf",
        "scarf/Packages/ScarfCore/Sources",
        "scarf/Scarf iOS",
    ]

    private static func swiftFiles(under relative: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    private static func isComment(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: .whitespaces)
        return bare.hasPrefix("//") || bare.hasPrefix("*")
    }

    /// Every `public static let X = managedRefusalAnchored…` in the markers
    /// file, found by reading the source rather than by a hand-kept list —
    /// the failure mode this replaces was exactly a hand-kept list going
    /// stale (finding 1).
    static func anchoredListNames(in source: String) -> [String] {
        var names: [String] = []
        for line in source.components(separatedBy: "\n") where !isComment(line) {
            guard line.contains("= managedRefusalAnchored"),
                  let letRange = line.range(of: "static let ")
            else { continue }
            let rest = line[letRange.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.append(String(name)) }
        }
        return names
    }

    @Test func everyAnchoredListIsPassedOnlyAtAnAnchoredLabel() throws {
        let markersPath = Self.repoRoot.appendingPathComponent(
            "scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift")
        let markers = try String(contentsOf: markersPath, encoding: .utf8)
        let names = Self.anchoredListNames(in: markers)
        #expect(names.count >= 6, Comment(rawValue:
            "the matcher found only \(names.count) anchored lists — it has stopped matching: \(names)"))

        var offenders: [String] = []
        for root in Self.scanRoots {
            for url in Self.swiftFiles(under: root) {
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lines = src.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    guard !Self.isComment(line) else { continue }
                    for name in names where line.contains(name) {
                        // Its own definition.
                        if line.contains("static let \(name)") { continue }
                        // The anchored label — the only correct way to hand
                        // one of these to `HermesCLIVerdict.judge`.
                        if line.contains("anchoredFailureMarkers:") { continue }
                        // …or an explicit `hasPrefix` match, which is what
                        // the label does internally (`sawServiceRefusal`).
                        let window = lines[i..<min(i + 4, lines.count)].joined(separator: "\n")
                        if window.contains("hasPrefix(") { continue }
                        offenders.append("\(url.lastPathComponent):\(i + 1) — "
                                         + line.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: """
            A list built on `managedRefusalAnchored` is used somewhere that \
            does not anchor it at column 0. These markers are Hermes's own \
            refusal sentences; matched unanchored, a run that merely QUOTES \
            one (an echoed command, a scan report) fails a successful write: \
            \(offenders.joined(separator: "; "))
            """))
    }
}
