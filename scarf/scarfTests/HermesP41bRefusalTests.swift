import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P41b — the round-4 review of P41's own four commits, app-target half.
///
/// Three findings land here: the identity-header refusal ran on the raw
/// draft although `save` writes it trimmed AND was not delta-gated although
/// the write is; the MCP entry reader split `key: value` with no quote
/// awareness, so an env/header name containing a colon round-tripped
/// corrupt; and no surface refused a map key past PyYAML's simple-key
/// length limit, which makes Hermes discard the whole config.yaml.
@Suite("P41b MCP editor and reader review")
struct HermesP41bRefusalTests {

    // MARK: - Fixtures

    private func server(
        transport: MCPTransport = .http,
        identityHeader: MCPIdentityHeader? = nil
    ) -> HermesMCPServer {
        HermesMCPServer(
            name: "srv", transport: transport,
            command: transport == .stdio ? "/usr/local/bin/tool" : nil, args: [],
            url: transport == .stdio ? nil : "https://mcp.example.com", auth: nil,
            env: [:], headers: [:], timeout: nil, connectTimeout: nil, enabled: true,
            toolsInclude: [], toolsExclude: [], resourcesEnabled: true,
            promptsEnabled: true, hasOAuthToken: false,
            identityHeader: identityHeader
        )
    }

    private func editor(_ s: HermesMCPServer) -> MCPServerEditorViewModel {
        MCPServerEditorViewModel(server: s, context: .local)
    }

    // MARK: - Finding 1: the identity header name is checked as the writer emits it

    /// `save` writes `identityHeaderNameDraft.trimmingCharacters(in: .whitespaces)`
    /// and `.whitespaces` contains the TAB, so a surrounding tab never
    /// reaches config.yaml — refusing it is the same over-refusal P41's own
    /// fresh-eyes pass fixed for the env/header keys and the tool filters,
    /// and it left the user staring at a field that looks fine.
    @Test(arguments: ["\tX-Id", "X-Id\t", "\t X-Id \t", " X-Id "])
    func surroundingWhitespaceOnTheIdentityNameIsNotRefused(_ draft: String) {
        let vm = editor(server())
        vm.identityHeaderEnabled = true
        vm.identityHeaderNameDraft = draft
        vm.identityHeaderValueFromDraft = .static
        vm.identityHeaderValueDraft = "v"
        #expect(vm.controlCharacterFieldLabel == nil,
                "the writer trims this away, so it is not a reason to refuse")
        #expect(vm.resolvedIdentityHeader?.name == "X-Id")
    }

    /// The clamp in the other direction: a tab INSIDE the name survives the
    /// trim, reaches the file, and is still refused.
    @Test(arguments: ["X\tId", "X\u{1B}Id", "X\u{7F}Id", "X\u{2029}Id"])
    func aControlInsideTheIdentityNameIsStillRefused(_ draft: String) {
        let vm = editor(server())
        vm.identityHeaderEnabled = true
        vm.identityHeaderNameDraft = draft
        vm.identityHeaderValueFromDraft = .static
        vm.identityHeaderValueDraft = "v"
        #expect(vm.controlCharacterFieldLabel == "Identity header name")
    }

    /// The VALUE is written raw — nothing trims it — so a surrounding tab
    /// there DOES reach the file and stays refused.
    @Test func aSurroundingTabOnTheIdentityValueIsStillRefused() {
        let vm = editor(server())
        vm.identityHeaderEnabled = true
        vm.identityHeaderNameDraft = "X-Id"
        vm.identityHeaderValueFromDraft = .static
        vm.identityHeaderValueDraft = "\tsecret"
        #expect(vm.controlCharacterFieldLabel == "Identity header value")
    }

    // MARK: - Finding 2: the identity header refusal is delta-gated

    /// An entry whose config.yaml already carries a control character in
    /// `identity_header.name` was completely uneditable: the refusal fired
    /// on every save although `save` only writes the block when it DIFFERS
    /// from the loaded value. Same rule as `client_cert` / `client_key` /
    /// `ssl_verify`, which P41 already delta-gated.
    @Test func anUnchangedIdentityHeaderWithAControlDoesNotBlockTheSave() {
        let loaded = MCPIdentityHeader(name: "X\u{1B}Id", valueFrom: .static, value: "v")
        let vm = editor(server(identityHeader: loaded))
        #expect(vm.identityHeaderNameDraft == "X\u{1B}Id", "premise: the draft loaded it")
        #expect(vm.identityHeaderEnabled, "premise: the section is on")
        #expect(vm.controlCharacterFieldLabel == nil,
                "an unchanged block is not written, so refusing it is over-refusal")
    }

    /// …and the user can still fix an unrelated field on that entry.
    @Test func anEntryWithAPoisonedIdentityHeaderIsStillEditableElsewhere() {
        let loaded = MCPIdentityHeader(name: "X\u{1B}Id", valueFrom: .static, value: "v")
        let vm = editor(server(identityHeader: loaded))
        vm.headersDraft = [.init(key: "Authorization", value: "Bearer abc123")]
        #expect(vm.controlCharacterFieldLabel == nil)
    }

    /// The clamp: once the user CHANGES the block, the write happens and the
    /// refusal must fire again.
    @Test func aChangedIdentityHeaderWithAControlIsRefused() {
        let loaded = MCPIdentityHeader(name: "X\u{1B}Id", valueFrom: .static, value: "v")
        let vm = editor(server(identityHeader: loaded))
        vm.identityHeaderValueDraft = "v2"
        #expect(vm.controlCharacterFieldLabel == "Identity header name")
    }

    /// Turning the section OFF on a poisoned entry resolves to `nil`, which
    /// is a delta — but there is nothing to refuse, and the block is removed.
    @Test func clearingAPoisonedIdentityHeaderIsNotRefused() {
        let loaded = MCPIdentityHeader(name: "X\u{1B}Id", valueFrom: .static, value: "v")
        let vm = editor(server(identityHeader: loaded))
        vm.identityHeaderEnabled = false
        #expect(vm.resolvedIdentityHeader == nil)
        #expect(vm.controlCharacterFieldLabel == nil)
    }

    // MARK: - Finding 4: an env/header key containing `:` round-trips

    /// Typing `A: B` as an env NAME saves correctly — `YAMLScalar.quoteIfNeeded`
    /// emits `'A: B': v` — but `HermesFileService`'s entry reader split on
    /// `trimmed.firstIndex(of: ":")` with no quote awareness, so it read the
    /// key back as `'A` with the value `B': v`, and the next save persisted
    /// THAT. The round trip runs through the real writer and the real reader.
    @Test(arguments: ["A: B", "llama3:8b", "ns::name", "X-Trace: id", "plain"])
    func anEnvKeyContainingAColonRoundTrips(_ key: String) throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try """
        mcp_servers:
          local_tool:
            command: /usr/local/bin/tool
            transport: stdio
            enabled: true
        """.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let service = HermesFileService(context: home.context)

        #expect(service.setMCPServerEnv(name: "local_tool", env: [key: "v"]))
        let entry = try #require(
            service.loadMCPServers().first { $0.name == "local_tool" }
        )
        #expect(entry.env[key] == "v", "read back as \(entry.env)")

        // And the second save — the one that used to persist the damage —
        // leaves the same single row.
        #expect(service.setMCPServerEnv(name: "local_tool", env: entry.env))
        let again = try #require(
            service.loadMCPServers().first { $0.name == "local_tool" }
        )
        #expect(again.env == [key: "v"], "second save changed it: \(again.env)")
    }

    /// The HTTP half — headers use the same reader and the same writer.
    @Test func aHeaderKeyContainingAColonRoundTrips() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try """
        mcp_servers:
          remote_api:
            url: https://my-mcp-server.example.com/mcp
            transport: http
            enabled: true
        """.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let service = HermesFileService(context: home.context)

        #expect(service.setMCPServerHeaders(name: "remote_api", headers: ["A: B": "v"]))
        let entry = try #require(
            service.loadMCPServers().first { $0.name == "remote_api" }
        )
        #expect(entry.headers == ["A: B": "v"], "read back as \(entry.headers)")
    }

    /// The clamp on the same change: an ordinary entry's scalars still read.
    /// `url:` values carry a colon of their own, which the separator rule
    /// (`first colon followed by whitespace`) has to get right.
    @Test func anOrdinaryEntryStillReadsItsScalars() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try """
        mcp_servers:
          remote_api:
            url: https://my-mcp-server.example.com:8443/mcp
            transport: http
            enabled: true
            timeout: 30
        """.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let entry = try #require(
            HermesFileService(context: home.context)
                .loadMCPServers().first { $0.name == "remote_api" }
        )
        #expect(entry.url == "https://my-mcp-server.example.com:8443/mcp")
        #expect(entry.transport == .http)
        #expect(entry.timeout == 30)
        #expect(entry.enabled)
    }

    // MARK: - Finding 6: PyYAML's simple-key length limit

    /// A key past 1024 emitted characters makes PyYAML's scanner raise
    /// (`yaml/scanner.py:283-291`), `load_config` discard the WHOLE
    /// config.yaml layer and fall back to `.env`
    /// (`gateway/config.py:775-791` @ `v2026.9.7`). Unlike the
    /// control-character refusal this is a parse guard, not a visibility one.
    @Test func anOversizedEnvKeyIsRefused() {
        let vm = editor(server(transport: .stdio))
        vm.envDraft = [.init(key: String(repeating: "A", count: 1025), value: "v")]
        #expect(vm.oversizedKeyFieldLabel == "Environment name")
    }

    @Test func anOversizedHeaderKeyIsRefused() {
        let vm = editor(server())
        vm.headersDraft = [.init(key: String(repeating: "A", count: 1025), value: "v")]
        #expect(vm.oversizedKeyFieldLabel == "Header name")
    }

    /// Quoting spends two characters of the budget rather than buying
    /// headroom — a colon in the name forces `'…'`, so the content limit
    /// drops to 1022.
    @Test func aQuotedKeyLosesTwoCharactersOfBudget() {
        let vm = editor(server(transport: .stdio))
        let body = { (n: Int) in "A: " + String(repeating: "a", count: n - 3) }
        vm.envDraft = [.init(key: body(1022), value: "v")]
        #expect(vm.oversizedKeyFieldLabel == nil)
        vm.envDraft = [.init(key: body(1023), value: "v")]
        #expect(vm.oversizedKeyFieldLabel == "Environment name")
    }

    /// The over-refusal clamps: a 1024-character bare key LOADS, and the
    /// limit is on the key, not the value.
    @Test func theLimitDoesNotOverRefuse() {
        let vm = editor(server(transport: .stdio))
        vm.envDraft = [.init(key: String(repeating: "A", count: 1024), value: "v")]
        #expect(vm.oversizedKeyFieldLabel == nil)

        let valueVM = editor(server(transport: .stdio))
        valueVM.envDraft = [.init(key: "TOKEN", value: String(repeating: "a", count: 9000))]
        #expect(valueVM.oversizedKeyFieldLabel == nil, "a long VALUE is legal YAML")

        let ordinary = editor(server(transport: .stdio))
        ordinary.envDraft = [.init(key: "TOKEN", value: "abc")]
        #expect(ordinary.oversizedKeyFieldLabel == nil)
    }

    /// The refusal is surfaced the way the sibling one is — before anything
    /// touches config.yaml, through `saveError`, with the field named.
    @Test func saveRefusesAnOversizedKeyAndWritesNothing() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let before = """
        mcp_servers:
          srv:
            command: /usr/local/bin/tool
            transport: stdio
        """
        try before.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)

        let vm = MCPServerEditorViewModel(
            server: server(transport: .stdio), context: home.context)
        vm.envDraft = [.init(key: String(repeating: "A", count: 1025), value: "v")]

        var reported: Bool?
        vm.save { reported = $0 }
        #expect(reported == false)
        #expect(vm.isSaving == false)
        let message = try #require(vm.saveError)
        #expect(message.contains("Environment name"))
        // P41c: the copy no longer names 1024 — the budget is the emitted
        // token, not a character count the user could check.
        #expect(message.contains("too long"))
        #expect(message.contains("1024") == false)
        #expect(try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
                == before, "config.yaml was touched by a refused save")
    }

    /// PyYAML itself is the authority on the boundary.
    ///
    /// P41c: the first cut wrapped the four boundary `#expect`s in
    /// `withKnownIssue(…, isIntermittent: true)` alongside the availability
    /// probe, so a disagreement with PyYAML was recorded as a known issue
    /// and the test could not fail — the lane was decorative. Only the
    /// PROBE is guarded now, exactly as `HermesP41MCPScalarTests`
    /// (`pyYAMLRoundTripLaneIsPresent`) does it; the boundaries are asserted
    /// unguarded, and the whole test returns early when python3/PyYAML is
    /// genuinely absent.
    private static func pyYAMLLoads(_ key: String) -> Bool? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", """
        import sys, yaml
        try:
            yaml.safe_load(sys.stdin.read())
            print("OK")
        except Exception:
            print("NO")
        """]
        let out = Pipe(), err = Pipe(), input = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input
        do { try proc.run() } catch { return nil }
        let doc = "env:\n  \(YAMLScalar.quoteIfNeeded(key)): v\n"
        input.fileHandleForWriting.write(Data(doc.utf8))
        input.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == "OK" || text == "NO" else { return nil }
        return text == "OK"
    }

    /// Named so the lane's ABSENCE is a reported known issue rather than a
    /// silent vacuous pass — and so that nothing else in this file is.
    @Test func pyYAMLBoundaryLaneIsPresent() {
        withKnownIssue(
            """
            PyYAML is not installed for `python3` on this machine — the \
            simple-key boundary lane of HermesP41bRefusalTests did NOT run. \
            Install it (`python3 -m pip install pyyaml`) to exercise the \
            lane that proves the refusal falls exactly where PyYAML does.
            """,
            isIntermittent: true
        ) {
            #expect(Self.pyYAMLLoads("ok") == true)
        }
    }

    // MARK: - Finding 5 (P41c): the MCP server NAME on the add path

    /// The add path shells `hermes mcp add`, and Hermes writes the server
    /// name through PyYAML's own EMITTER
    /// (`hermes_cli/mcp_config.py:_save_mcp_server` → `hermes_cli/config.py:save_config`
    /// → `utils.py:atomic_yaml_write`, which is `yaml.dump` @ `v2026.9.7`).
    /// The emitter does not produce a simple key it could not read back: past
    /// its line width it switches to the EXPLICIT `? key` / `: value` form,
    /// which carries no simple-key limit at all. So an over-long name is
    /// neither refused by Hermes nor written as a file Hermes cannot reload —
    /// `hermes mcp add` succeeds and every sibling entry survives.
    ///
    /// That is why the add path gets NO length pre-check: the refusal the
    /// editor carries exists because SCARF emits those keys itself
    /// (`env`/`headers` names, reasoning-override patterns) as simple keys;
    /// the server name is not one Scarf emits, and refusing it would be the
    /// over-refusal P19 named. `mcp_security.validate_mcp_server_entry`
    /// (`hermes_cli/mcp_security.py:89`) has no length rule either, so there
    /// is no Hermes refusal to judge the output of.
    @Test func anOverLongServerNameSurvivesHermesOwnEmitter() throws {
        guard Self.pyYAMLLoads("ok") == true else { return }
        let name = String(repeating: "A", count: 1100)
        let script = """
        import sys, yaml, json
        name = sys.stdin.read()
        doc = yaml.dump(
            {"mcp_servers": {name: {"command": "x"}, "ok": {"command": "y"}}},
            default_flow_style=False, sort_keys=False, allow_unicode=True)
        back = yaml.safe_load(doc)
        print(json.dumps({
            "explicit": doc.startswith("mcp_servers:\\n  ? "),
            "keys": sorted(len(k) for k in back["mcp_servers"]),
        }))
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        let out = Pipe(), err = Pipe(), input = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input
        try proc.run()
        input.fileHandleForWriting.write(Data(name.utf8))
        input.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        let text = String(decoding: data, as: UTF8.self)
        // The emitter chose `? key`, and BOTH entries reload.
        #expect(text.contains("\"explicit\": true"), "emitter did not use the explicit-key form: \(text)")
        #expect(text.contains("[2, 1100]"), "the document did not reload intact: \(text)")

        // Scarf's own simple-key rule still says this name would be illegal
        // if Scarf emitted it as `name:` — which is exactly why the rule is
        // applied where Scarf emits and not where Hermes does.
        #expect(YAMLScalar.exceedsSimpleKeyLimit(name))
    }

    @Test func pyYAMLAgreesOnWhereTheLimitFalls() throws {
        // The ZWJ family is one Character and seven unicode scalars; the
        // combining pair is one Character and two. PyYAML counts scalars,
        // which is why `String.count` was the wrong measure (P41c).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        // One case per side of each boundary: (key, does PyYAML load it?).
        let cases: [(String, Bool)] = [
            (String(repeating: "a", count: 1024), true),
            (String(repeating: "a", count: 1025), false),
            ("A: " + String(repeating: "a", count: 1019), true),    // emits 1024
            ("A: " + String(repeating: "a", count: 1020), false),   // emits 1025
            (String(repeating: "e\u{301}", count: 512), true),      // 1024 scalars, 512 Characters
            (String(repeating: "e\u{301}", count: 513), false),     // 1026 scalars, 513 Characters
            (String(repeating: family, count: 146), true),          // 1022 scalars, 146 Characters
            (String(repeating: family, count: 147), false),         // 1029 scalars, 147 Characters
        ]

        // Absence is reported by `pyYAMLBoundaryLaneIsPresent`; here it only
        // decides whether there is anything to compare against.
        guard Self.pyYAMLLoads("ok") == true else { return }

        for (key, expected) in cases {
            let emitted = YAMLScalar.quoteIfNeeded(key).unicodeScalars.count
            let actual = try #require(Self.pyYAMLLoads(key),
                                      "python3 could not be run for the \(emitted)-scalar case")
            #expect(actual == expected,
                    "PyYAML disagrees at \(emitted) emitted scalars")
            #expect(YAMLScalar.exceedsSimpleKeyLimit(key) == !expected,
                    "the refusal disagrees with PyYAML at \(emitted) emitted scalars")
        }
    }
}
