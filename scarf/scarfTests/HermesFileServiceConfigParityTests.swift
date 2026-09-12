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
      streaming: false
    max_concurrent_sessions: 5
    display:
      personality: kawaii
      # Set EXPLICITLY (and to the opposite of `model.streaming` below) so the
      # "these two keys are not the same key" assertion stays meaningful
      # without leaning on either one's default. `display.streaming` in fact
      # defaults to FALSE upstream — `hermes_cli/config_defaults.py:796` and
      # its reader `cli.py:2598` at v2026.9.7, `hermes_cli/config.py:220` at
      # v2026.3.17 (v0.3.0) — which this fixture used to assert backwards.
      streaming: true
      resume_display: minimal
      busy_input_mode: queue
      timestamps: true
      language: en
      bell_on_prompt: true
      resume_last_session: false
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
    agent:
      service_tier: cold
      fast_auto_seconds: 15
    updates:
      check: false
    gateway:
      trust_env: false
    tool_loop_guardrails:
      non_interactive_hard_stop_enabled: false
    delegation:
      independent_completions: true
      compression_threshold_tokens: 200000
    telemetry:
      shared_metrics:
        enabled: true
        send: true
        endpoint: https://staging.example.test/v1/telemetry
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
        // `rich_messages` is a SENTINEL now (the shipped default flipped
        // true -> false at v0.18), so the fixture's explicit `false` must
        // arrive as `.some(false)`, not as "absent".
        #expect(config.telegram.richMessages == false)
        #expect(config.telegram.statusIndicator == true)
        #expect(config.whatsappCloud.phoneNumberID == "123456")
        #expect(config.whatsappCloud.dmPolicy == "allowlist")
    }

    /// Hermes v0.21.1 (tag v2026.9.7) keys — the Settings batch shipped in
    /// the v0.21.1 parity cycle. Four of these default TRUE upstream, so
    /// the fixture sets every one of them to its NON-default value: a
    /// reader that dropped the key would fall back to the default and the
    /// assertion would fail, which is exactly the drift this suite exists
    /// to catch.
    @Test func v0211KeysRoundTrip() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        // A4 — service tier + its bounded-window length.
        #expect(HermesServiceTier.normalize(config.serviceTier) == .cold)
        #expect(config.agentFastAutoSeconds == 15)
        // A5 — the two independent telemetry opt-ins and the endpoint.
        #expect(config.telemetry.sharedMetricsEnabled == true)
        #expect(config.telemetry.sharedMetricsSend == true)
        #expect(config.telemetry.sharedMetricsEndpointHost == "staging.example.test")
        // C9 — the true-by-default four, all explicitly false here.
        #expect(config.updatesCheck == false)
        #expect(config.gatewayTrustEnv == false)
        #expect(config.modelStreaming == false)
        #expect(config.toolLoopNonInteractiveHardStop == false)
        #expect(config.display.resumeLastSession == false)
        // C9 — the rest.
        #expect(config.display.bellOnPrompt == true)
        #expect(config.delegation.independentCompletions == true)
        #expect(config.delegation.compressionThresholdTokens == 200_000)
        // `model.streaming` (false above) must not have been mistaken for
        // `display.streaming` (true in the fixture) — the two are read from
        // different blocks and mean different things.
        #expect(config.streaming == true)
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
///
/// Every OTHER config writer in the app — `LocalModelConfigPlan` included —
/// is covered by `AllConfigWritersParityTests` at the bottom of this file,
/// which widened this gate after the `gateway_restart_notification` bug
/// shipped from a writer this suite never looked at.
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
        #"auxiliary.\(task).max_concurrency"#,
        #"auxiliary.title_generation.\(field)"#,
    ]

    /// Fields the Title Generation section writes via
    /// `setTitleGeneration(field:)` (AuxiliaryTab); enabled/timeout/
    /// reasoning_effort/language go through dedicated literal setters.
    private static let titleGenerationFields = ["provider", "model", "base_url", "api_key"]

    static func expandedAuxKeys() -> [String] {
        auxTasks.flatMap { task in
            (auxFields + ["reasoning_effort", "max_concurrency"]).map { "auxiliary.\(task).\($0)" }
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

    static func signature(_ config: HermesConfig) -> [String] {
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

    /// `a.b.c` + one entry → nested block YAML whose leaf is a MAP, so
    /// map-valued keys (`agent.reasoning_overrides`, read into
    /// `maps[...]`) perturb the parse where neither a scalar nor a bullet
    /// list would. Needed once the direct-YAML writers came under the
    /// gate: `hermes config set` cannot express a map, which is exactly
    /// why those surfaces splice the YAML themselves.
    private static func mapYAML(key: String, entry: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        var lines = parts.enumerated().map { (i, part) in
            String(repeating: "  ", count: i) + "\(part):"
        }
        lines.append(String(repeating: "  ", count: parts.count) + "\(entry): \(entry)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A key is "read" if at least one sentinel shape moves a field off its
    /// default. Covers string, bool (both directions — some defaults are
    /// `true`), int, block-list, and block-map readers.
    static func isKeyReadable(_ key: String, defaultSignature: [String]) -> Bool {
        let candidates = [
            scalarYAML(key: key, value: sentinel),
            scalarYAML(key: key, value: "true"),
            scalarYAML(key: key, value: "false"),
            scalarYAML(key: key, value: "424242"),
            listYAML(key: key, item: sentinel),
            mapYAML(key: key, entry: sentinel),
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

// MARK: - Repo-wide config-writer parity gate

/// Widens `SettingsWriteReadParityTests` from ONE file to EVERY config
/// writer in the app.
///
/// The narrow gate scanned `SettingsViewModel.swift` only. That is not
/// where all config keys are written: `GatewayBehaviorViewModel` builds its
/// own `hermes config set` batch, `AdvancedTab` calls `setSetting` straight
/// from the view, `QuickCommandsViewModel` / `CredentialPoolsViewModel`
/// compose dotted keys inline, every platform-setup VM ships a `configKV`
/// dictionary, and `LocalModelConfigPlan` (ScarfCore) emits its own argv.
/// The `gateway_restart_notification` bug — the toggle wrote the nested
/// `gateway.platforms.<p>.…` path nobody reads, and the reader then
/// contradicted it on the next load — survived a full release precisely
/// because that writer sat outside the gate.
///
/// Two independent guards:
///
/// 1. **Writer discovery.** Every source file under the app / iOS / ScarfCore
///    trees is scanned for config-write markers. The discovered set must
///    equal `knownWriters`. A NEW writer file fails here until it is
///    registered — no writer can be added silently.
/// 2. **Key readability.** Every config key literal those files write must
///    round-trip through `HermesConfig(yaml:)`, same detector as the narrow
///    gate. A wrong / unread path (the restart-notification class) fails.
///
/// Non-literal key arguments (the shared executors that take a `key`
/// parameter, and the genuinely computed keys) can't be read off the
/// source, so each writer declares how many it has plus the concrete
/// expansion. A new computed shape pushes the count past the declaration
/// and fails — it cannot slip through unchecked.
struct AllConfigWritersParityTests {

    // MARK: Writer manifest

    /// One registered config-writing source file.
    struct Writer {
        /// Path relative to the project dir (the parent of `scarfTests`).
        let path: String
        /// How many config-write call sites in this file pass a NON-literal
        /// key (a `key` parameter, or an interpolated/computed expression).
        /// Every one of them must be accounted for by `computedKeys`.
        let nonLiteralKeySites: Int
        /// Concrete keys those non-literal sites can produce, enumerated so
        /// the readability gate can still check them.
        let computedKeys: [String]
    }

    /// Sample values used to make an interpolated key concrete. The gate
    /// checks the SHAPE of the path, so any legal segment works.
    private static let sampleQuickCommand = "deploy"
    private static let sampleProvider = "openai"
    private static let sampleMCPServer = "github"

    /// Keys `SettingsViewModel` splices straight into `config.yaml` through
    /// `saveDirectYAML` rather than `hermes config set` — scanned off the
    /// `label:` argument, which by construction IS the dotted key each
    /// caller writes. Scanned rather than hard-coded so a fourth
    /// direct-YAML surface is covered the moment it lands.
    /// **The gate keys on a LABEL string, which is fragile (GW-F6 / audit DI
    /// L9).** `label:` is a display/log argument that happens to be the
    /// dotted config key at all three call sites; nothing in the type system
    /// says it must be, and a future caller passing `"Reasoning overrides"`
    /// would silently shrink the covered set rather than fail. Two cheap
    /// defences below: `directYAMLSiteCount` pins how many call sites the
    /// scan is supposed to find (so a renamed method or an added site trips
    /// the count, not the coverage), and `directYAMLKeysAreDottedConfigKeys`
    /// asserts each scraped label is shaped like a config path. Together
    /// they turn "the gate quietly stopped checking" into a red test.
    static var directYAMLKeys: [String] {
        guard let source = try? read("scarf/Features/Settings/ViewModels/SettingsViewModel.swift")
        else { return [] }
        return matches(#"saveDirectYAML\(label:\s*"([^"]+)""#, in: stripComments(source))
    }

    /// The number of `saveDirectYAML(label:` call sites this gate expects.
    /// Bump it deliberately when a fourth direct-YAML surface lands.
    static let directYAMLSiteCount = 3

    @Test func directYAMLKeysAreDottedConfigKeysAndComplete() throws {
        let keys = Self.directYAMLKeys
        #expect(keys.count == Self.directYAMLSiteCount, """
            Expected \(Self.directYAMLSiteCount) `saveDirectYAML(label:` sites, found \(keys.count): \(keys).
            Either a direct-YAML surface was added (extend `directYAMLSiteCount`) or the \
            scan's regex no longer matches the call shape — in which case this gate has \
            silently stopped covering those keys.
            """)
        for key in keys {
            // A config key is dotted-lowercase-with-underscores. A prose
            // label ("Reasoning overrides") fails on the space and the caps.
            #expect(
                key.range(of: #"\A[a-z0-9_]+(\.[a-z0-9_]+)*\z"#, options: .regularExpression) != nil,
                "`saveDirectYAML(label: \"\(key)\")` is not shaped like a config key. The parity gate treats the label AS the key it writes; a prose label makes that key invisible to it."
            )
        }
    }

    /// Platforms whose gateway-behavior toggles Scarf actually writes —
    /// scanned off the `GatewayBehaviorSection(platform: "…")` call sites so
    /// a newly-wired platform is covered automatically instead of needing a
    /// second list here to be kept in sync.
    static func gatewayBehaviorPlatforms() -> [String] {
        let views = swiftFiles().filter { $0.contains("Features/Platforms/Views") }
        var out: Set<String> = []
        for rel in views {
            guard let source = try? read(rel) else { continue }
            out.formUnion(matches(#"GatewayBehaviorSection\(\s*platform:\s*"([^"]+)""#, in: source))
        }
        return out.sorted()
    }

    /// The restart-notification keys those platforms produce, expanded by
    /// CALLING the production key builder — the path is pinned by shipping
    /// code, not by a copy of it in the test.
    private static var gatewayRestartNotificationKeys: [String] {
        gatewayBehaviorPlatforms().map {
            GatewayBehaviorViewModel.restartNotificationKey(platform: $0, capabilities: .empty)
        }
    }

    private static var knownWriters: [Writer] {
        [
            // 7 non-literal sites: `setSetting`'s
            // `["config", "set", key, value]` argv (keys come from the
            // scanned `setSetting(` literals) plus the six interpolated
            // `setSetting("auxiliary.\(task)…")` writers, which
            // `SettingsWriteReadParityTests` already pins by template and
            // expands into concrete keys.
            // …plus 1 direct-YAML site (`saveDirectYAML`'s shared guarded
            // `file.write(updated, to: path, …)`), whose three callers name
            // the key they splice in their `label:`.
            // The `unset` argv used to be the ninth, spelled inline here; it
            // moved to `HermesConfigUnset.argv(key:)` in P35 so both platforms
            // build (and judge) it the same way. The KEYS are unchanged — they
            // are still this file's own `unsetSetting("…")` literals, which
            // the scan sees.
            //
            // P39 made that ninth site VISIBLE again rather than adding one:
            // `setSetting`'s inline argv moved onto `HermesConfigSet.argv`, and
            // the scan learned the builder shape — so the `HermesConfigUnset`
            // call P35 had hidden from it is now counted too. Same keys, same
            // gate; one more declared site.
            Writer(path: "scarf/Features/Settings/ViewModels/SettingsViewModel.swift",
                   nonLiteralKeySites: 9,
                   computedKeys: SettingsWriteReadParityTests.expandedAuxKeys()
                    + directYAMLKeys),
            // The shared `hermes config set` / `config unset` argv builders. One
            // non-literal site by construction — the key is its PARAMETER —
            // and no keys of its own. P39 added the `config set` twin
            // (``HermesConfigSet``), so it is two. Every caller (`SettingsViewModel`'s
            // `unsetSetting` literals and iOS's `SettingEditorSheet`, whose
            // key is a `SettingSpec.key` already in the manifest below) is
            // itself registered, so the readability gate still sees them.
            Writer(path: "Packages/ScarfCore/Sources/ScarfCore/Services/HermesCLIOutcome.swift",
                   nonLiteralKeySites: 2, computedKeys: []),
            // iOS Settings. It was INVISIBLE to this gate until P39, because
            // it built its argv into a shell script string
            // (`"… \(hermes) config set \(shellEscape(key)) …"`) that no marker
            // could see; routing it through the shared builders put it in the
            // discovered set, where it belongs. Two non-literal sites — `set`
            // and `unset`, both taking `key` as a parameter — and no keys of
            // its own: every key it can write is a `SettingSpec.key`, and
            // `SettingsEditorSpecParityTests` already pins those.
            Writer(path: "Packages/ScarfCore/Sources/ScarfCore/ViewModels/IOSSettingsViewModel.swift",
                   nonLiteralKeySites: 2, computedKeys: []),
            // iOS chat's model preflight. Newly VISIBLE rather than newly
            // written (P46 finding 12): it has always written these two keys,
            // but through a hand-rolled shell string
            // (`"\(hermes) config set 'model.provider' '…'"`) that no marker
            // could see — and, being hand-rolled, without the `--` and judged
            // by exit code. Routing it through `HermesConfigSet.argv`/`.judge`
            // put it in the discovered set, where it belongs. One non-literal
            // site (the shared `runConfigSet(_:hermes:key:value:)` helper,
            // whose `key` is a parameter); its two concrete keys are declared
            // here because the callers pass them as arguments, not as argv
            // literals the scan can read.
            Writer(path: "Scarf iOS/Chat/ChatView.swift",
                   nonLiteralKeySites: 1,
                   computedKeys: ["model.provider", "model.default"]),
            Writer(path: "scarf/Features/Settings/Views/Tabs/AdvancedTab.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Core/Services/HermesFileService.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            // Shared executor: keys arrive from each platform VM's configKV.
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/PlatformSetupHelpers.swift",
                   nonLiteralKeySites: 1, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/GatewayBehaviorViewModel.swift",
                   nonLiteralKeySites: 1,
                   computedKeys: gatewayRestartNotificationKeys),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/DiscordSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/TelegramSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/SlackSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/MatrixSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            // P51: became a config writer when `mattermost.require_mention`
            // moved off `.env` onto the side the adapter actually prefers
            // (`plugins/platforms/mattermost/adapter.py:491-494`, `:504` @
            // `v2026.9.7`). The gate caught it on the first run, which is
            // what it is for.
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/MattermostSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/SignalSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/WhatsAppSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/WhatsAppCloudSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/EmailSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/NtfySetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/Platforms/ViewModels/PlatformSetup/HomeAssistantSetupViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/QuickCommands/ViewModels/QuickCommandsViewModel.swift",
                   nonLiteralKeySites: 2,
                   computedKeys: [
                    "quick_commands.\(sampleQuickCommand).type",
                    "quick_commands.\(sampleQuickCommand).command",
                   ]),
            Writer(path: "scarf/Features/Personalities/ViewModels/PersonalitiesViewModel.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "scarf/Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift",
                   nonLiteralKeySites: 1,
                   computedKeys: ["credential_pool_strategies.\(sampleProvider)"]),
            // ScarfCore's model-picker plan. Its argv sites take a `key`
            // parameter; the concrete keys are the literals in the same file
            // (`model.default`/`provider`/`base_url`/`api_key`/`api_mode`)
            // plus `model.context_length`, cleared through the managed-key
            // list rather than a `.clear(key: "…")` literal.
            // Shared direct-YAML executor for the gateway allowlists: one
            // guarded write site whose `platform` / `key` both arrive as
            // parameters from `GatewayBehaviorViewModel`.
            Writer(path: "Packages/ScarfCore/Sources/ScarfCore/Services/GatewayConfigWriter.swift",
                   nonLiteralKeySites: 1, computedKeys: []),
            // (GW-E2a) Newly VISIBLE rather than newly written: this actor has
            // always spliced `platform_toolsets.<platform>` directly, but it
            // did so through a raw transport write that no marker could see.
            // Routing it through the shared `GuardedTextFile` put it in the
            // discovered set, where it belongs. It writes no `key: value`
            // setting — it inserts/removes a `- kanban` list item — so it has
            // no non-literal KEY sites and nothing for the readability gate.
            Writer(path: "Packages/ScarfCore/Sources/ScarfCore/Services/KanbanToolsetEnabler.swift",
                   nonLiteralKeySites: 0, computedKeys: []),
            Writer(path: "Packages/ScarfCore/Sources/ScarfCore/Services/LocalModelConfigPlan.swift",
                   nonLiteralKeySites: 2,
                   computedKeys: ["model.context_length"]),
            // Per-bot agent config (Bot Mode Phase B). The shared
            // `setValue`/`unsetValue` executors take a `key` parameter (the
            // two non-literal sites); the concrete keys they can produce are
            // the model pin pair plus the interpolated MCP enablement key.
            // Writes go to the BOT profile's config.yaml via `-p <bot>`, and
            // reads come back through this service's own direct-file parse,
            // not the root HermesConfig — hence the external reader below
            // for the MCP key.
            Writer(path: "Packages/ScarfCore/Sources/ScarfCore/Services/BotAgentConfigService.swift",
                   nonLiteralKeySites: 2,
                   computedKeys: [
                    "model.default",
                    "model.provider",
                    "mcp_servers.\(sampleMCPServer).enabled",
                   ]),
        ]
    }

    // MARK: Source roots + discovery

    private static var projectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/<proj>
    }

    private static let sourceRoots = ["scarf", "Scarf iOS", "Packages/ScarfCore/Sources"]

    /// Any of these in a file means it writes at least one config KEY.
    /// Deliberately excludes `configKV: [:]` (a platform VM with no config
    /// keys) and bare `configKV` parameter mentions.
    private static let writerMarkers = [
        #"(?:un)?setSetting\("#,
        #""config",\s*"(?:set|unset)""#,
        // P39: the shared `config set`/`config unset` argv builders.
        #"Hermes(?:ConfigSet|ConfigUnset)\.argv\(\s*key:"#,
        #"configKV\s*\[\s*""#,
        #"configKV:\s*\[String:\s*String\]\s*=\s*\[\s*\n"#,
        // Direct-YAML writers. `hermes config set` stringifies arrays and
        // can't express a sequence-of-mappings, so the list/map surfaces
        // (gateway allowlists, agent.reasoning_overrides,
        // model_catalog.excluded_providers, profile_routes) bypass the CLI
        // and splice `~/.hermes/config.yaml` themselves. None of the argv
        // or `setSetting` markers above can see that shape — before this
        // marker `SettingsViewModel` was only caught INCIDENTALLY, by its
        // unrelated `setSetting` calls, so a brand-new file whose ONLY
        // config writes were direct-YAML splices walked straight past
        // Guard 1. Both orderings are listed because the path constant and
        // the write can appear either way round in a file; requiring BOTH
        // tokens keeps non-config `writeText` callers (SOUL.md, the iOS
        // memory snapshot) out of the discovered set.
        // (GW-E2a) The direct-YAML writers now publish through the shared
        // `GuardedTextFile` instead of `context.unguardedWriteText`, so the
        // marker follows the guard.
        //
        // (GW-E2c) It matches the guard's LABEL rather than spanning from a
        // `GuardedTextFile(` to a `paths.configYAML` anywhere later in the
        // file. That span was a false positive by construction the moment a
        // second file guarded some OTHER text file and also happened to
        // mention `paths.configYAML` — which `SkillsViewModel` does, guarding
        // `SKILL.md` while reading config.yaml to compute missing config. All
        // five config.yaml writers name the label on the construction line,
        // and the label is the thing that actually says "this writes
        // config.yaml".
        #"GuardedTextFile\([^\n]*label:\s*"config\.yaml""#,
    ]

    private static func swiftFiles() -> [String] {
        var out: [String] = []
        for root in sourceRoots {
            let base = projectDir.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let rel as String in e where rel.hasSuffix(".swift") {
                out.append("\(root)/\(rel)")
            }
        }
        return out.sorted()
    }

    private static func matches(_ pattern: String, in source: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
        }
    }

    private static func count(_ pattern: String, in source: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))
            .map { $0.numberOfMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) } ?? 0
    }

    private static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: projectDir.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Source with `//` comment tails removed, so prose never counts as a
    /// call site or contributes a key.
    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    // MARK: Key extraction

    /// Literal config keys a writer file spells out, across every write
    /// shape the app uses.
    static func literalKeys(in source: String) -> (staticKeys: [String], interpolated: [String]) {
        var found: [String] = []
        found += matches(#"(?:un)?setSetting\("([^"]*)""#, in: source)
        found += matches(#""config",\s*"(?:set|unset)",\s*"(?!--")([^"]*)""#, in: source)
        // P39: the shared argv builders. A call site that spells its key
        // literally here is exactly as checkable as the inline array it
        // replaced, and must stay in the readability gate.
        found += matches(#"Hermes(?:ConfigSet|ConfigUnset)\.argv\(\s*key:\s*"([^"]*)""#, in: source)
        found += matches(#"configKV\["([^"]*)"\]"#, in: source)
        found += matches(#"\.(?:set|clear)\(key:\s*"([^"]*)""#, in: source)
        found += configKVDictionaryKeys(in: source)
        return (found.filter { !$0.contains(#"\("#) }, found.filter { $0.contains(#"\("#) })
    }

    /// Keys of a `let configKV: [String: String] = [ "k": v, … ]` literal.
    /// Scans from the opening bracket to the matching close so a `"…"`
    /// elsewhere in the file is never mistaken for an entry.
    private static func configKVDictionaryKeys(in source: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"configKV:\s*\[String:\s*String\]\s*=\s*\["#) else { return [] }
        let ns = source as NSString
        var keys: [String] = []
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            var depth = 1
            var i = m.range.upperBound
            var inString = false
            var block = ""
            while i < ns.length, depth > 0 {
                let c = ns.substring(with: NSRange(location: i, length: 1))
                if c == "\"" { inString.toggle() }
                if !inString {
                    if c == "[" { depth += 1 }
                    if c == "]" { depth -= 1; if depth == 0 { break } }
                }
                block += c
                i += 1
            }
            keys += matches(#"^\s*"([^"]+)"\s*:"#, in: block)
                + matches(#"\n\s*"([^"]+)"\s*:"#, in: block)
        }
        return keys
    }

    // MARK: Keys deliberately outside HermesConfig

    /// A key whose reader is NOT `HermesConfig(yaml:)` but a dedicated
    /// per-feature parser. Legitimate — those surfaces are maps/lists keyed
    /// by user-chosen names, which `HermesConfig`'s fixed struct can't model
    /// — but each one still has to name the reader, and the gate asserts
    /// that reader really does look the path up (`readerLiteral`). An
    /// unread key can therefore never hide behind a hand-waved exemption.
    struct ExternalReader {
        let key: String
        let readerPath: String
        let readerLiteral: String
    }

    private static var externalReaders: [ExternalReader] {
        [
            .init(key: "quick_commands.\(sampleQuickCommand).type",
                  readerPath: "Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesQuickCommandsYAML.swift",
                  readerLiteral: "\"quick_commands.\""),
            .init(key: "quick_commands.\(sampleQuickCommand).command",
                  readerPath: "Packages/ScarfCore/Sources/ScarfCore/Parsing/HermesQuickCommandsYAML.swift",
                  readerLiteral: "\"quick_commands.\""),
            .init(key: "credential_pool_strategies.\(sampleProvider)",
                  readerPath: "scarf/Features/CredentialPools/ViewModels/CredentialPoolsViewModel.swift",
                  readerLiteral: "\"credential_pool_strategies\""),
            .init(key: "platforms.email.extra.skip_attachments",
                  readerPath: "scarf/Features/Platforms/ViewModels/PlatformSetup/EmailSetupViewModel.swift",
                  readerLiteral: "\"platforms.email.extra.skip_attachments\""),
            .init(key: "mcp_servers.\(sampleMCPServer).enabled",
                  readerPath: "Packages/ScarfCore/Sources/ScarfCore/Services/BotAgentConfigService.swift",
                  readerLiteral: "\"mcp_servers.\""),
        ]
    }

    /// Keys Scarf writes for HERMES to consume and never reads back, by
    /// design. Each needs a reason; the list must stay tiny.
    ///
    /// * `platforms.whatsapp_cloud.enabled` — derived on save from whether
    ///   phone_number_id + access_token are both filled in. Scarf recomputes
    ///   it from those two fields on every load, so reading the flag back
    ///   would add a second source of truth, not remove one.
    private static let writeOnlyKeys: Set<String> = [
        "platforms.whatsapp_cloud.enabled",
    ]

    // MARK: Tests

    /// Guard 1 — no config writer may exist outside the manifest.
    @Test func everyConfigWriterFileIsRegistered() throws {
        var discovered: Set<String> = []
        for rel in Self.swiftFiles() {
            let source = Self.stripComments(try Self.read(rel))
            if Self.writerMarkers.contains(where: { Self.count($0, in: source) > 0 }) {
                discovered.insert(rel)
            }
        }
        let known = Set(Self.knownWriters.map(\.path))
        let unregistered = discovered.subtracting(known).sorted()
        let stale = known.subtracting(discovered).sorted()
        #expect(unregistered.isEmpty, """
            Config-writing source file(s) not registered in \
            AllConfigWritersParityTests.knownWriters: \
            \(unregistered.joined(separator: ", ")). Register each (with its \
            non-literal key sites and their concrete expansions) so its keys \
            go through the write/read parity gate.
            """)
        #expect(stale.isEmpty, """
            Registered writer(s) no longer write config keys — drop them from \
            knownWriters: \(stale.joined(separator: ", "))
            """)
    }

    /// Guard 2 — every key any registered writer writes must be read back
    /// by `HermesConfig(yaml:)`. A wrong nested path (the
    /// `gateway_restart_notification` bug) is unread and fails here.
    @Test func everyWrittenKeyAcrossAllWritersIsReadable() throws {
        var keys: Set<String> = []
        for writer in Self.knownWriters {
            let source = Self.stripComments(try Self.read(writer.path))
            let (staticKeys, _) = Self.literalKeys(in: source)
            keys.formUnion(staticKeys)
            keys.formUnion(writer.computedKeys)
        }
        // Sanity: the multi-shape scan must actually find the surface.
        #expect(keys.count >= 200,
                "Repo-wide scan found only \(keys.count) config keys — scan likely broke")

        keys.subtract(Self.externalReaders.map(\.key))
        keys.subtract(Self.writeOnlyKeys)

        let defaultSignature = SettingsWriteReadParityTests.signature(HermesConfig(yaml: ""))
        let unread = keys.sorted().filter {
            !SettingsWriteReadParityTests.isKeyReadable($0, defaultSignature: defaultSignature)
        }
        #expect(unread.isEmpty, """
            \(unread.count) config key(s) are WRITTEN somewhere in Scarf but NOT \
            read back by HermesConfig(yaml:) — they save then reload stale, or \
            (worse) they are a wrong path nothing has ever read. Fix the path or \
            add the reader in ScarfCore's HermesConfig+YAML.swift: \
            \(unread.joined(separator: ", "))
            """)
    }

    /// Guard 2b — the escape hatch can't be abused. Every key exempted as
    /// "read by a dedicated parser" must actually appear in that parser's
    /// source, and must NOT be readable through `HermesConfig` (otherwise
    /// the exemption is dead weight hiding the key from the real gate).
    @Test func externalReaderExemptionsAreRealAndStillNeeded() throws {
        let defaultSignature = SettingsWriteReadParityTests.signature(HermesConfig(yaml: ""))
        for entry in Self.externalReaders {
            let reader = try Self.read(entry.readerPath)
            #expect(reader.contains(entry.readerLiteral), """
                \(entry.key) is exempted from the parity gate as "read by \
                \(entry.readerPath)", but that file does not contain \
                \(entry.readerLiteral) — the exemption is stale.
                """)
            #expect(!SettingsWriteReadParityTests.isKeyReadable(entry.key, defaultSignature: defaultSignature), """
                \(entry.key) IS readable through HermesConfig now — drop the \
                externalReaders exemption so the real gate covers it.
                """)
        }
    }

    /// Guard 3 — every non-literal key site must be declared. A new
    /// computed/interpolated writer shape pushes the real count past the
    /// manifest and fails here instead of silently skipping the gate.
    @Test func nonLiteralKeySiteCountsMatchTheManifest() throws {
        for writer in Self.knownWriters {
            let source = Self.stripComments(try Self.read(writer.path))
            // Every config-write call site in the file…
            let argvSites = Self.count(#""config",\s*"(?:set|unset)","#, in: source)
                + Self.count(#"Hermes(?:ConfigSet|ConfigUnset)\.argv\(\s*key:"#, in: source)
            let setSettingSites = Self.count(#"(?:un)?setSetting\("#, in: source)
                - Self.count(#"func\s+(?:un)?setSetting\("#, in: source)
            let configKVSites = Self.count(#"configKV\["#, in: source)
            // Direct-YAML splice sites. The key is never a literal at the
            // write itself (it lives in the transform / the caller's
            // arguments), so each one is by definition a non-literal site
            // and must be declared.
            // GW-F3 moved the config.yaml writers onto `GuardedTextFile`'s
            // locked `mutate`, which publishes the transform's return value
            // instead of calling `write` with it — so the splice site is now
            // `file.mutate(path)` at those adopters. Both shapes count: the
            // gate is about the KEY never being a literal at the write, and
            // that is equally true either way.
            let directYAMLSites =
                Self.count(#"file\.write\(\s*updated\s*,\s*to:\s*path\s*,"#, in: source)
                + Self.count(#"file\.mutate\(\s*path\s*\)\s*\{[^}]*\bupdated\b"#, in: source)
            let sites = argvSites + setSettingSites + configKVSites + directYAMLSites
            // …minus those whose key the scan captured as a FULLY STATIC
            // literal. An interpolated literal (`"quick_commands.\(name).type"`)
            // is a matched literal but NOT a checkable key, so it counts as
            // non-literal and must be declared with its expansion.
            let literalArgv = Self.matches(#""config",\s*"(?:set|unset)",\s*"(?!--")([^"]*)""#, in: source)
                + Self.matches(#"Hermes(?:ConfigSet|ConfigUnset)\.argv\(\s*key:\s*"([^"]*)""#, in: source)
            let literalSetSetting = Self.matches(#"(?:un)?setSetting\("([^"]*)""#, in: source)
            let literalConfigKV = Self.matches(#"configKV\["([^"]*)"\]"#, in: source)
            let staticLiterals = (literalArgv + literalSetSetting + literalConfigKV)
                .filter { !$0.contains(#"\("#) }
                .count
            let nonLiteral = sites - staticLiterals
            #expect(nonLiteral == writer.nonLiteralKeySites, """
                \(writer.path): found \(nonLiteral) non-literal config-key site(s), \
                manifest declares \(writer.nonLiteralKeySites). A key written through \
                a computed expression evades the readability gate — update \
                knownWriters with the site count AND the concrete keys it produces.
                """)
        }
    }
}

/// Whole-surface audit P13 — the three config DEFAULTS that were wrong, read
/// through the Mac app's real `HermesFileService.loadConfig()` path (not the
/// ScarfCore parser directly), plus the two Settings controls whose option
/// list / seed value came from those reads.
///
/// The fixture is a config.yaml that omits all three keys, which is the only
/// case a default can be observed in — the suite above pins the
/// explicitly-set values.
struct HermesConfigDefaultsP13ParityTests {

    /// A config.yaml with none of the audited keys present.
    private static let bareYAML = """
    model:
      default: llama3.1:8b
      provider: ollama
    display:
      personality: default
    """

    private func loadBare() throws -> (config: HermesConfig, cleanup: () -> Void) {
        let home = try TempHermesHome()
        try Self.bareYAML.write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        return (HermesFileService(context: home.context).loadConfig(), home.cleanup)
    }

    /// `openrouter.response_cache` -> true (`config_defaults.py:649` at
    /// v2026.9.7; `config.py:686` at the key's floor v2026.5.7 = v0.13.0).
    /// `display.streaming` -> false (`config_defaults.py:796` and its reader
    /// `cli.py:2598`; `config.py:220` at v2026.3.17 = v0.3.0, the floor).
    /// `platforms.telegram.extra.rich_messages` -> nil, a sentinel, because
    /// the shipped value flipped True (v0.17.0 `config.py:2144`) -> False
    /// (v0.18.0 `config.py:2367`, still False at v2026.9.7
    /// `config_defaults.py:1492`).
    @Test func auditedDefaultsMatchHermes() throws {
        let (config, cleanup) = try loadBare()
        defer { cleanup() }
        #expect(config.openrouterResponseCacheEnabled == true)
        #expect(config.streaming == false)
        #expect(config.telegram.richMessages == nil)
        // …and the sentinel resolves per host generation.
        #expect(config.displayTelegramRichMessages(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)")))
        #expect(!config.displayTelegramRichMessages(
            capabilities: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")))
    }

    /// The Approval Mode picker's options ARE `_VALID_MODES`
    /// (`tools/approval_context.py:197` @ v2026.9.7) — no `auto`, which
    /// Hermes has warned-and-discarded at every tag back to v0.3.0.
    @Test func approvalModePickerOffersOnlyValidModes() {
        #expect(HermesApprovalMode.options == ["manual", "smart", "off"])
        // And a config still carrying the invalid value renders as the mode
        // the host enforces, so the picker is never blank.
        #expect(HermesApprovalMode.normalize("auto").rawValue == "manual")
    }

    /// The Busy Input Mode picker gains `steer` only where Hermes reads it
    /// (`cli.py:2592` @ v2026.9.7; the reader's floor is v2026.4.30 =
    /// v0.12.0), and never renders a blank selection over a value Scarf did
    /// not expect.
    @Test func busyInputModePickerOptionsFollowTheHost() {
        let v0211 = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
        let v011 = HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")
        #expect(DisplayTab.busyInputModeOptions(current: "interrupt", capabilities: v0211)
            == ["interrupt", "queue", "steer"])
        #expect(DisplayTab.busyInputModeOptions(current: "interrupt", capabilities: v011)
            == ["interrupt", "queue"])
        // Unknown version keeps today's rendering (C1).
        #expect(DisplayTab.busyInputModeOptions(current: "interrupt", capabilities: .empty)
            == ["interrupt", "queue"])
        // A stored value the host does not offer is still selectable rather
        // than leaving the control blank.
        #expect(DisplayTab.busyInputModeOptions(current: "steer", capabilities: v011)
            == ["interrupt", "queue", "steer"])
        #expect(DisplayTab.busyInputModeOptions(current: "wat", capabilities: v0211)
            == ["interrupt", "queue", "steer", "wat"])
    }

    /// The WAL Autocheckpoint "Custom" toggle must seed SQLite's own default
    /// (1000 pages), not the range's lower bound. `hermes_state_wal.py:466-487`
    /// passes the configured int straight into `PRAGMA
    /// wal_autocheckpoint=<n>`, where 0 DISABLES automatic checkpointing —
    /// so the old seed turned "let me set a value" into "let the WAL grow
    /// without bound".
    @Test func walAutocheckpointCustomSeedsSQLiteDefault() {
        #expect(AdvancedTab.walAutocheckpointSQLiteDefault == 1000)
        #expect(AdvancedTab.customToggleValue(
            current: nil, seed: AdvancedTab.walAutocheckpointSQLiteDefault,
            lowerBound: 0) == 1000)
        // An already-set value always wins over the seed…
        #expect(AdvancedTab.customToggleValue(
            current: 0, seed: AdvancedTab.walAutocheckpointSQLiteDefault,
            lowerBound: 0) == 0)
        // …and a row with no explicit seed keeps the old lower-bound
        // behaviour (Journal Size Limit, where 0 is a legitimate setting).
        #expect(AdvancedTab.customToggleValue(current: nil, seed: nil, lowerBound: 0) == 0)
    }
}
