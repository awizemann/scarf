import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Pins the Mac app's config-read path to ScarfCore's canonical parser.
///
/// Regression guard for the Settings "dropdowns save but never show the
/// selected value" bug: `HermesFileService.parseConfig` was a duplicated
/// copy of `HermesConfig(yaml:)` and drifted — v0.17/v0.18 keys
/// (`web.search_backend`, `curator.consolidate`, `image_gen.model`, …)
/// were added only to the ScarfCore copy, so after every save the Mac
/// reload snapped those fields back to defaults and the Picker rendered
/// a stale/blank selection. `loadConfig()` now routes through
/// `HermesConfig(yaml:)`; these tests fail if a second mapping ever
/// reappears on the app side or the round-trip loses a key again.
///
/// The service-level assertion IS the VM/Picker contract:
/// `SettingsViewModel.setSetting` does `config = fileService.loadConfig()`
/// after a successful `hermes config set`, and every `PickerRow` reads
/// its `selection` straight off `viewModel.config`.
struct HermesFileServiceConfigParityTests {

    /// Shape mirrors a real v0.17 `~/.hermes/config.yaml` (the exact
    /// sections Hermes's YAML dumper emits), restricted to the keys the
    /// drifted Mac parser used to drop plus a few long-standing ones to
    /// prove the parser swap lost nothing.
    private static let fixtureYAML = """
    model:
      default: llama3.1:8b
      provider: ollama
      base_url: http://127.0.0.1:11434/v1
      context_length: 32768
    max_concurrent_sessions: 5
    display:
      personality: kawaii
      resume_display: minimal
      busy_input_mode: queue
      timestamps: true
      language: en
    terminal:
      backend: docker
      docker_extra_args:
        - --privileged
        - --network=host
    web:
      backend: tavily
      search_backend: firecrawl
      extract_backend: exa
    image_gen:
      model: dall-e-3
    openrouter:
      response_cache: true
    curator:
      consolidate: true
    platforms:
      telegram:
        extra:
          rich_messages: false
          status_indicator: true
      whatsapp_cloud:
        extra:
          phone_number_id: '123456'
          dm_policy: allowlist
    human_delay:
      mode: 'off'
    """

    private func loadFixture() throws -> (config: HermesConfig, cleanup: () -> Void) {
        let home = try TempHermesHome()
        try Self.fixtureYAML.write(
            toFile: home.context.paths.configYAML,
            atomically: true,
            encoding: .utf8
        )
        let config = HermesFileService(context: home.context).loadConfig()
        return (config, home.cleanup)
    }

    /// The dropdowns Alan hit: Web Tools search/extract/combined backends.
    /// Pre-fix the Mac parser read NO `web.*` key, so the pickers rendered
    /// a blank selection forever no matter what was saved.
    @Test func webToolsBackendsRoundTrip() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        #expect(config.webToolsBackend == "tavily")
        #expect(config.webToolsSearchBackend == "firecrawl")
        #expect(config.webToolsExtractBackend == "exa")
    }

    /// The rest of the drifted key set — every Settings surface that
    /// saved-but-never-displayed on Mac.
    @Test func v017AndV018KeysRoundTrip() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        #expect(config.curatorConsolidate == true)
        #expect(config.maxConcurrentSessions == 5)
        #expect(config.imageGenModel == "dall-e-3")
        #expect(config.openrouterResponseCacheEnabled == true)
        #expect(config.display.timestamps == true)
        #expect(config.terminal.dockerExtraArgs == ["--privileged", "--network=host"])
        #expect(config.telegram.richMessages == false)
        #expect(config.telegram.statusIndicator == true)
        #expect(config.whatsappCloud.phoneNumberID == "123456")
        #expect(config.whatsappCloud.dmPolicy == "allowlist")
    }

    /// Long-standing keys survive the parser swap (parity floor).
    @Test func classicKeysStillParse() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        #expect(config.model == "llama3.1:8b")
        #expect(config.provider == "ollama")
        #expect(config.modelBaseURL == "http://127.0.0.1:11434/v1")
        #expect(config.modelContextLength == "32768")
        #expect(config.personality == "kawaii")
        #expect(config.display.resumeDisplay == "minimal")
        #expect(config.display.busyInputMode == "queue")
        #expect(config.display.language == "en")
        #expect(config.terminalBackend == "docker")
        #expect(config.humanDelay.mode == "off")
    }

    /// The save→reload flow the Settings pickers depend on: overwrite the
    /// file with a new value (what `hermes config set` does) and confirm a
    /// fresh `loadConfig()` — exactly what `setSetting` assigns back to
    /// `SettingsViewModel.config` — exposes the new selection.
    @Test func reloadAfterWriteExposesNewSelection() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let svc = HermesFileService(context: home.context)

        try "web:\n  search_backend: tavily\n".write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        #expect(svc.loadConfig().webToolsSearchBackend == "tavily")

        try "web:\n  search_backend: firecrawl\n".write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        #expect(svc.loadConfig().webToolsSearchBackend == "firecrawl")
    }
}

// MARK: - Derived write/read parity gate

/// Converts the "new config keys go in ScarfCore only" convention from
/// documentation into a BUILD GATE.
///
/// `HermesFileServiceConfigParityTests` above is a *fixed-fixture* guard:
/// it pins ~20 hand-picked keys and proves the parser swap lost nothing.
/// It does NOT enumerate the ~120 `SettingsViewModel.setSetting(...)`
/// writers, so a NEW writer added without a matching `HermesConfig(yaml:)`
/// reader saves-but-reloads-stale silently — the `web_tools.*` / dropdown
/// bug class that has already bitten twice.
///
/// This suite closes that surface. It SCANS `SettingsViewModel.swift` at
/// test time, extracts every dotted config key the Mac app writes through
/// `setSetting`, and asserts each is *read back* by `HermesConfig(yaml:)`.
///
/// ## Enumeration approach — SOURCE SCAN
/// Swift has no runtime reflection over string-literal call arguments, so
/// the writer set can't be recovered from a compiled binary. Instead the
/// test reads the VM's own source (located via `#filePath` → repo root)
/// and greps the `setSetting("<key>", …)` call sites. Static literals are
/// pulled directly; the two *interpolated* shapes
/// (`auxiliary.\(task).\(field)`, `auxiliary.\(task).timeout`) are
/// enumerated against the concrete task/field lists the Auxiliary tab
/// writes. The scan is deliberately strict: if a NEW interpolated writer
/// shape appears that isn't in the known set, `unresolvedInterpolatedShapes`
/// FAILS rather than silently skipping it (see that test).
///
/// ## Read-back detection — no per-key accessor map
/// Rather than maintain a fragile key→field lookup, the test injects a
/// non-default sentinel for each key into a minimal nested YAML, parses it
/// through `HermesConfig(yaml:)`, and structurally diffs the result
/// (via `Mirror`) against the all-default parse. If *no* sentinel shape
/// (string / bool both ways / int / block-list) perturbs a single field,
/// the key is unread → the key is reported. This needs no production
/// `Equatable`/accessor changes and catches a write-without-reader the
/// moment it lands.
///
/// ## Scope boundary
/// The gate covers `SettingsViewModel.setSetting` keys only — the 120-writer
/// drift class named in the memory note. `LocalModelConfigPlan` is a
/// *separate* write path (model.base_url / api_key / api_mode /
/// context_length / supports_vision); those are excluded here to respect
/// its ownership and because `supports_vision` is read by
/// `RichChatViewModel`'s own scalar lookup, not modelled on `HermesConfig`.
/// The reader coverage of the model.* trio is already pinned by
/// `classicKeysStillParse` above.
struct SettingsWriteReadParityTests {

    // MARK: Source location

    /// Absolute path to `SettingsViewModel.swift`, derived from this test
    /// file's compile-time location. Layout:
    ///   <proj>/scarfTests/HermesFileServiceConfigParityTests.swift  (#filePath)
    ///   <proj>/scarf/Features/Settings/ViewModels/SettingsViewModel.swift
    private static var settingsViewModelPath: String {
        URL(fileURLWithPath: #filePath)          // …/scarfTests/<this file>
            .deletingLastPathComponent()          // …/scarfTests
            .deletingLastPathComponent()          // …/<proj>
            .appendingPathComponent("scarf/Features/Settings/ViewModels/SettingsViewModel.swift")
            .path
    }

    private static func readSource() throws -> String {
        try String(contentsOfFile: settingsViewModelPath, encoding: .utf8)
    }

    // MARK: Interpolated-writer enumeration (Auxiliary tab)

    /// Aux task names the Auxiliary tab writes — `AuxiliaryTab.baseTasks`
    /// plus the two capability-gated rows (flush_memories, curator). These
    /// must match the `aux(_:)` names in `HermesConfig+YAML.swift`.
    private static let auxTasks = [
        "vision", "web_extract", "compression", "session_search",
        "skills_hub", "approval", "mcp", "flush_memories", "curator",
    ]
    /// Fields the Auxiliary tab writes: `setAuxiliary` (provider/model/
    /// base_url/api_key) + `setAuxiliaryTimeout` (timeout).
    private static let auxFields = ["provider", "model", "base_url", "api_key", "timeout"]

    /// The interpolated `setSetting` templates the scan knows how to expand.
    /// Kept as raw literals so the scan can assert the source contains
    /// exactly these (and fail loudly on a new shape).
    private static let knownInterpolatedTemplates: Set<String> = [
        #"auxiliary.\(task).\(field)"#,
        #"auxiliary.\(task).timeout"#,
        #"auxiliary.\(task).reasoning_effort"#,
        #"auxiliary.title_generation.\(field)"#,
    ]

    /// Fields the Title Generation section writes via
    /// `setTitleGeneration(field:)` (AuxiliaryTab); enabled/timeout/
    /// reasoning_effort/language go through dedicated literal setters.
    private static let titleGenerationFields = ["provider", "model", "base_url", "api_key"]

    private static func expandedAuxKeys() -> [String] {
        auxTasks.flatMap { task in
            (auxFields + ["reasoning_effort"]).map { "auxiliary.\(task).\($0)" }
        } + titleGenerationFields.map { "auxiliary.title_generation.\($0)" }
    }

    // MARK: Key extraction

    /// Every `setSetting("<literal>"` first-argument literal. Partitioned
    /// into static (no `\(` interpolation) and interpolated.
    private static func setSettingLiterals(in source: String) throws
        -> (staticKeys: [String], interpolated: [String]) {
        // First arg of setSetting up to the closing quote of the literal.
        // `[^"]*` so an interpolated literal (with `\(`) is captured whole.
        let regex = try NSRegularExpression(pattern: #"setSetting\("([^"]*)""#)
        let ns = source as NSString
        var staticKeys: [String] = []
        var interpolated: [String] = []
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let literal = ns.substring(with: m.range(at: 1))
            if literal.contains(#"\("#) {
                interpolated.append(literal)
            } else {
                staticKeys.append(literal)
            }
        }
        return (staticKeys, interpolated)
    }

    // MARK: Structural signature (Mirror)

    /// Flatten any value into a sorted list of `path=leaf` strings. Dicts
    /// are key-sorted so ordering never causes a spurious diff; optionals
    /// and collections recurse. Two configs share a signature iff every
    /// stored field is equal.
    private static func flatten(_ value: Any, path: String, into out: inout [String]) {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .struct, .class:
            for child in mirror.children {
                flatten(child.value, path: "\(path).\(child.label ?? "?")", into: &out)
            }
        case .optional:
            if let child = mirror.children.first {
                flatten(child.value, path: path, into: &out)
            } else {
                out.append("\(path)=nil")
            }
        case .collection:
            var i = 0
            for child in mirror.children {
                flatten(child.value, path: "\(path)[\(i)]", into: &out)
                i += 1
            }
        case .dictionary:
            var entries: [String] = []
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                let key = pair.first.map { String(describing: $0.value) } ?? "?"
                var sub: [String] = []
                if pair.count >= 2 { flatten(pair[1].value, path: "\(path){\(key)}", into: &sub) }
                entries.append(sub.sorted().joined(separator: "|"))
            }
            out.append(contentsOf: entries.sorted())
        default:
            out.append("\(path)=\(String(describing: value))")
        }
    }

    private static func signature(_ config: HermesConfig) -> [String] {
        var out: [String] = []
        flatten(config, path: "root", into: &out)
        return out.sorted()
    }

    // MARK: Sentinel YAML builders

    private static let sentinel = "__scarf_parity_sentinel__"

    /// `a.b.c` + scalar → nested block YAML.
    private static func scalarYAML(key: String, value: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        var lines: [String] = []
        for (i, part) in parts.enumerated() {
            let indent = String(repeating: "  ", count: i)
            lines.append(i == parts.count - 1 ? "\(indent)\(part): \(value)" : "\(indent)\(part):")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `a.b.c` + item → nested block YAML with a one-element bullet list,
    /// so genuine list keys (e.g. `terminal.docker_extra_args`) perturb the
    /// parsed `lists[...]` where a scalar never would.
    private static func listYAML(key: String, item: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        var lines = parts.enumerated().map { (i, part) in
            String(repeating: "  ", count: i) + "\(part):"
        }
        lines.append(String(repeating: "  ", count: parts.count) + "- \(item)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A key is "read" if at least one sentinel shape moves a field off its
    /// default. Covers string, bool (both directions — some defaults are
    /// `true`), int, and block-list readers.
    private static func isKeyReadable(_ key: String, defaultSignature: [String]) -> Bool {
        let candidates = [
            scalarYAML(key: key, value: sentinel),
            scalarYAML(key: key, value: "true"),
            scalarYAML(key: key, value: "false"),
            scalarYAML(key: key, value: "424242"),
            listYAML(key: key, item: sentinel),
        ]
        for yaml in candidates where signature(HermesConfig(yaml: yaml)) != defaultSignature {
            return true
        }
        return false
    }

    // MARK: Tests

    /// The gate. Every `setSetting` writer key (static + expanded aux) must
    /// round-trip a non-default value through `HermesConfig(yaml:)`. A key
    /// that saves but never reads back is reported — add its reader to
    /// `HermesConfig+YAML.swift` (ScarfCore), never a Mac-side mapping.
    @Test func everyWrittenSettingKeyIsReadableThroughScarfCore() throws {
        let source = try Self.readSource()
        let (staticKeys, _) = try Self.setSettingLiterals(in: source)

        // Sanity: the scan must find the writer surface. If this collapses
        // (e.g. a refactor renamed `setSetting`), the gate is toothless.
        #expect(staticKeys.count >= 100,
                "Source scan found only \(staticKeys.count) static setSetting keys — scan likely broke")

        let keys = Set(staticKeys).union(Self.expandedAuxKeys()).sorted()
        let defaultSignature = Self.signature(HermesConfig(yaml: ""))

        let unread = keys.filter { !Self.isKeyReadable($0, defaultSignature: defaultSignature) }
        #expect(unread.isEmpty, """
            \(unread.count) config key(s) are WRITTEN by SettingsViewModel.setSetting \
            but NOT read back by HermesConfig(yaml:) — they save then reload stale. \
            Add the reader to ScarfCore's HermesConfig+YAML.swift (never a Mac-side \
            mapping): \(unread.joined(separator: ", "))
            """)
    }

    /// Guards the enumeration itself: the only interpolated `setSetting`
    /// shapes may be the two the aux expansion understands. A new
    /// interpolated writer (e.g. `setSetting("providers.\(p).enabled", …)`)
    /// must be added to `knownInterpolatedTemplates` + its expansion, so it
    /// can't slip past the parity gate unchecked.
    @Test func unresolvedInterpolatedShapesFailLoudly() throws {
        let source = try Self.readSource()
        let (_, interpolated) = try Self.setSettingLiterals(in: source)
        let found = Set(interpolated)
        let unknown = found.subtracting(Self.knownInterpolatedTemplates)
        #expect(unknown.isEmpty, """
            New interpolated setSetting shape(s) the parity scan can't expand: \
            \(unknown.sorted().joined(separator: ", ")). Add each to \
            knownInterpolatedTemplates and enumerate its concrete keys.
            """)
    }

    /// Guards the SCAN itself against a silent evasion: every `setSetting(`
    /// call site in the source must be a string-literal first argument the
    /// regex actually captured. A writer added as `setSetting(\n  "key", …)`
    /// (newline after the paren) or `setSetting(someConstant, …)` (non-literal
    /// key) would otherwise slip past `setSetting\("` entirely — no static and
    /// no interpolated match — leaving its key unchecked while the ≥100 sanity
    /// count still passes. Counting call sites and matched literals closes that
    /// hole: any unmatched call site fails here.
    @Test func everySetSettingCallSiteIsAScannedLiteral() throws {
        // Strip `//`-comment tails so prose mentioning `setSetting(` (like
        // this very method's doc comment) never inflates the call-site count
        // — only real code occurrences count.
        let source = try Self.readSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
        let ns = source as NSString
        // All `setSetting(` textual occurrences, minus the func declaration
        // (`func setSetting(`). What remains are call sites.
        let allCalls = try NSRegularExpression(pattern: #"setSetting\("#)
            .numberOfMatches(in: source, range: NSRange(location: 0, length: ns.length))
        // `unsetSetting(` contains `setSetting(` as a substring, so its
        // declaration must be subtracted too; unsetSetting CALL sites stay
        // in the gate deliberately — an unset key is still a managed key
        // whose literal the parity scan should capture.
        let declarations = try NSRegularExpression(pattern: #"func\s+(?:un)?setSetting\("#)
            .numberOfMatches(in: source, range: NSRange(location: 0, length: ns.length))
        let callSites = allCalls - declarations

        let (staticKeys, interpolated) = try Self.setSettingLiterals(in: source)
        let matched = staticKeys.count + interpolated.count

        #expect(callSites == matched, """
            \(callSites - matched) setSetting call site(s) were NOT captured as a \
            string literal by the parity scan (call sites: \(callSites), matched \
            literals: \(matched)). A key written via a non-literal first argument \
            or a newline after `setSetting(` evades the write/read gate. Make the \
            first argument a same-line string literal, or extend the scan.
            """)
    }

    /// Proves the detector actually fails a written-but-unread key: a
    /// fabricated key Hermes/ScarfCore never reads must be reported unread.
    /// This is the negative control for `everyWrittenSettingKeyIsReadable…`.
    @Test func fabricatedUnreadKeyIsDetected() throws {
        let defaultSignature = Self.signature(HermesConfig(yaml: ""))
        #expect(!Self.isKeyReadable("scarf.fake_unread_key", defaultSignature: defaultSignature))
        // And a real reader is detected as readable (positive control).
        #expect(Self.isKeyReadable("web.search_backend", defaultSignature: defaultSignature))
    }
}
