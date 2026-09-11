import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P19 — the MCP `env:` / `headers:` map-KEY writer, the duplicate-row trap,
/// the `yamlScalar` line-break guard, and the BOM.
///
/// P10 put every MCP scalar VALUE through `yamlScalar` and left the map keys
/// bare, so a key the user typed was spliced into config.yaml raw. Hermes
/// swallows a PyYAML error and discards the user's ENTIRE config.yaml layer
/// (`gateway/config.py:775-791` at `v2026.9.7`), and `verifyPatchedConfig`
/// passed the damage: `entryNames` only reads indent 0/2, and
/// `unpatchableReason` skipped the `#`-prefixed line a `#`-leading key
/// produced.
@Suite("P19 MCP YAML map keys")
struct MCPYAMLMapKeyP19Tests {

    // MARK: - PyYAML harness

    private static let pyYAMLAvailable: Bool = { run("import yaml") != nil }()

    @discardableResult
    private static func run(_ script: String, stdin text: String = "") -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script]
        let out = Pipe(), err = Pipe(), input = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input
        do { try proc.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(text.utf8))
        input.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `repr(yaml.safe_load(stdin)['mcp_servers'][server][block])`, or nil
    /// when PyYAML refuses the document.
    private static func block(_ yaml: String, _ server: String, _ block: String) -> String? {
        let script = """
        import sys,yaml
        d = yaml.safe_load(sys.stdin.read())
        print(repr(d['mcp_servers']['\(server)']['\(block)']))
        """
        return run(script, stdin: yaml)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parses(_ yaml: String) -> Bool {
        run("import sys,yaml; yaml.safe_load(sys.stdin.read())", stdin: yaml) != nil
    }

    /// The lane that proves Hermes can still READ what Scarf writes. Named
    /// as a known issue rather than silently evaporating when PyYAML is not
    /// installed for `python3`.
    @Test func pyYAMLRoundTripLaneIsPresent() {
        withKnownIssue(
            """
            PyYAML is not installed for `python3` on this machine — the \
            round-trip half of MCPYAMLMapKeyP19Tests did NOT run. Install it \
            (`python3 -m pip install pyyaml`) to exercise the lane that \
            proves Hermes can still read what Scarf writes.
            """,
            isIntermittent: true
        ) {
            #expect(Self.pyYAMLAvailable)
        }
    }

    // MARK: - Fixture

    private static let fixtureYAML = """
    mcp_servers:
      remote_api:
        url: https://my-mcp-server.example.com/mcp
        transport: http
        enabled: true
    """

    private func loadFixture(
        prefix: String = ""
    ) throws -> (service: HermesFileService, home: TempHermesHome) {
        let home = try TempHermesHome()
        try (prefix + Self.fixtureYAML).write(
            toFile: home.context.paths.configYAML,
            atomically: true,
            encoding: .utf8
        )
        return (HermesFileService(context: home.context), home)
    }

    private func readConfig(_ home: TempHermesHome) throws -> String {
        try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
    }

    // MARK: - Finding 1: map keys are quoted

    /// Each of these keys is legal for a user to type into the editor and
    /// illegal (or silently reshaping) as a BARE YAML key. Verified against
    /// PyYAML 6 at indent 6 under `headers:`: `{a}` / `[x]` raise
    /// `ConstructorError`, `a: b` and a tabbed key raise `ScannerError`,
    /// `*z` raises `ComposerError` (undefined alias), a leading `#` turns
    /// the whole mapping into `None`, and `on` becomes the key `True`.
    @Test(arguments: ["{a}", "[x]", "a: b", "A\tB", "*z", "#note", "on", "007", "~"])
    func hazardousHeaderKeysAreQuotedAndReadBackVerbatim(_ key: String) throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerHeaders(name: "remote_api", headers: [key: "v"]))
        let written = try readConfig(home)

        // Structural half: the key is not in the file bare.
        #expect(!written.contains("      \(key): v"))
        #expect(written.contains(YAMLScalar.quoteIfNeeded(key)))

        guard Self.pyYAMLAvailable else { return }
        #expect(Self.parses(written), "Hermes would discard the whole config.yaml layer")
        // Read back as the STRING the user typed — not None, not True.
        #expect(Self.block(written, "remote_api", "headers") == "{\(pyRepr(key)): 'v'}")

        // And the bare spelling — what the writer emitted before P19 — does
        // NOT survive: it either fails to parse or loads as something else.
        let bare = Self.fixtureYAML + "\n    headers:\n      \(key): v\n"
        #expect(
            Self.block(bare, "remote_api", "headers") != "{\(pyRepr(key)): 'v'}",
            "bare `\(key)` must not round-trip — if it does, this test proves nothing"
        )
    }

    /// The env writer is the same code path and gets the same guarantee.
    @Test(arguments: ["{a}", "a: b", "#note", "on"])
    func hazardousEnvKeysAreQuotedAndReadBackVerbatim(_ key: String) throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerEnv(name: "remote_api", env: [key: "v"]))
        let written = try readConfig(home)
        guard Self.pyYAMLAvailable else { return }
        #expect(Self.parses(written))
        #expect(Self.block(written, "remote_api", "env") == "{\(pyRepr(key)): 'v'}")
    }

    /// An ordinary key keeps its byte-for-byte plain spelling — the quoting
    /// widening must not churn every config in the world.
    @Test func ordinaryKeysStayBare() throws {
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerEnv(name: "remote_api", env: ["API_KEY": "abc123"]))
        #expect(try readConfig(home).contains("      API_KEY: abc123"))
    }

    /// Python's `repr` for the key, so the expectation reads as the dict
    /// PyYAML actually returns.
    private func pyRepr(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "'\(escaped)'"
    }

    // MARK: - Finding 1b: the verifier fails CLOSED

    /// `patchMCPServerField(expecting:)` is what turns "the file still looks
    /// like a file" into "the rows we wrote are in it". A row that is
    /// missing — because a key commented its own mapping out, say — must
    /// make the whole patch restore.
    @Test func subMapRowsAreTheRowsTheWriterEmits() throws {
        let rows = HermesFileService.subMapRows(header: "headers", map: ["#note": "v", "b": "2"])
        #expect(rows.first == "    headers:")
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerHeaders(name: "remote_api", headers: ["#note": "v", "b": "2"]))
        let written = try readConfig(home)
        for row in rows {
            #expect(written.contains(row), "the verifier's expected row is not in the file: \(row)")
        }
    }

    /// `unpatchableReason` used to accept any indent-4-or-deeper line with a
    /// colon in it, so a key carrying a flow indicator — the exact damage
    /// the pre-P19 writer produced — passed the verification meant to catch
    /// it.
    @Test func unpatchableReasonRejectsAFlowIndicatorKey() {
        let entry = [
            "  remote_api:",
            "    transport: http",
            "    headers:",
            "      {a}: v"
        ]
        let reason = HermesFileService.unpatchableReason(entryLines: entry)
        #expect(reason?.contains("flow indicator") == true, "got \(reason ?? "nil")")

        // A QUOTED key of the same text is fine — that is what we now write.
        #expect(HermesFileService.unpatchableReason(entryLines: [
            "  remote_api:",
            "    transport: http",
            "    headers:",
            "      '{a}': v"
        ]) == nil)

        // But the gate must NOT over-refuse: a plain key carrying a comma or
        // a mid-token brace is legal YAML that Hermes reads fine (verified
        // against PyYAML 6: `a,b`, `a}b`, `a[b` all load as plain keys), and
        // refusing it would make an ordinary config uneditable.
        for key in ["A,B", "A}B", "A[B", "A#B"] {
            #expect(HermesFileService.unpatchableReason(entryLines: [
                "  remote_api:",
                "    headers:",
                "      \(key): v"
            ]) == nil, "refused a legal plain key: \(key)")
        }

        // And a tab inside the key, which PyYAML refuses outright.
        #expect(HermesFileService.unpatchableReason(entryLines: [
            "  remote_api:",
            "    headers:",
            "      A\tB: v"
        ])?.contains("tab inside the key") == true)
    }

    // MARK: - Finding 2: duplicate rows no longer trap the process

    /// `Dictionary(uniqueKeysWithValues:)` on user input is a precondition
    /// failure, i.e. the whole app dies on Save. Two rows keyed `" API_KEY"`
    /// and `"API_KEY"` collide after the trim.
    @Test func duplicateRowKeysAreDetectedAfterTrimming() {
        let rows = [
            MCPServerEditorViewModel.KeyValueRow(key: " API_KEY", value: "a"),
            MCPServerEditorViewModel.KeyValueRow(key: "API_KEY", value: "b")
        ]
        #expect(MCPServerEditorViewModel.duplicateKey(in: rows) == "API_KEY")
        // Blank rows (what `appendEnvRow` creates) are not duplicates.
        #expect(MCPServerEditorViewModel.duplicateKey(in: [
            MCPServerEditorViewModel.KeyValueRow(key: "", value: ""),
            MCPServerEditorViewModel.KeyValueRow(key: "", value: ""),
            MCPServerEditorViewModel.KeyValueRow(key: "A", value: "1")
        ]) == nil)
    }

    @MainActor
    @Test func savingWithDuplicateEnvKeysReportsAValidationErrorAndWritesNothing() async throws {
        let home = try TempHermesHome()
        try Self.fixtureYAML.write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8
        )
        let before = try readConfig(home)
        let vm = MCPServerEditorViewModel(
            server: HermesMCPServer(
                name: "remote_api", transport: .stdio, command: "x", args: [],
                url: nil, auth: nil, env: [:], headers: [:],
                timeout: nil, connectTimeout: nil, enabled: true,
                toolsInclude: [], toolsExclude: [], resourcesEnabled: true,
                promptsEnabled: true, hasOAuthToken: false, sslVerify: nil
            ),
            context: home.context
        )
        vm.envDraft = [
            .init(key: "API_KEY", value: "a"),
            .init(key: " API_KEY ", value: "b")
        ]
        let ok: Bool = await withCheckedContinuation { continuation in
            vm.save { continuation.resume(returning: $0) }
        }
        #expect(!ok)
        #expect(vm.isSaving == false)
        #expect(vm.saveError?.contains("API_KEY") == true)
        #expect(try readConfig(home) == before, "a refused save must not touch config.yaml")
    }

    // MARK: - Finding 6: `yamlScalar` line-break guard

    /// `GatewayConfigWriter` has had a line-break guard since P10; this twin
    /// had none, so a `cwd` / `client_cert` / `command` carrying a `\n` was
    /// spliced into a line and left a column-0 fragment behind.
    @Test func yamlScalarEscapesLineBreaksInsteadOfSplicingThem() throws {
        #expect(HermesFileService.yamlScalar("/a\nb") == #""/a\nb""#)
        #expect(HermesFileService.yamlScalar("/a\r\nb") == #""/a\r\nb""#)
        // Lossless: the reader undoes the escape.
        #expect(HermesFileService.unquote(HermesFileService.yamlScalar("/a\nb")) == "/a\nb")

        let (service, home) = try loadFixture()
        #expect(service.setMCPServerClientCert(name: "remote_api", path: "/certs/a\nb.pem"))
        let written = try readConfig(home)
        #expect(!written.contains("\nb.pem: "))
        guard Self.pyYAMLAvailable else { return }
        #expect(Self.parses(written))
        let cert = Self.run(
            """
            import sys,yaml
            print(repr(yaml.safe_load(sys.stdin.read())['mcp_servers']['remote_api']['client_cert']))
            """,
            stdin: written
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cert == #"'/certs/a\nb.pem'"#)
    }

    /// An implicitly-typed scalar VALUE is quoted too: an env value of
    /// `007` used to load as the int 7.
    ///
    /// P41 moved `yamlScalar` onto `YAMLScalar.quoteIfNeeded`, so the
    /// SPELLING of the quote changed (single, not double) while the rule did
    /// not. The assertion is therefore "quoted, and PyYAML reads the string
    /// back" rather than a byte-exact double-quoted form — pinning the
    /// spelling would pin the copy P41 deleted.
    @Test(arguments: ["007", "~", "0x1F", "2026-09-09", "on", ".inf"])
    func yamlScalarQuotesImplicitlyTypedValues(_ raw: String) {
        let emitted = HermesFileService.yamlScalar(raw)
        #expect(emitted != raw, "`\(raw)` went out bare and PyYAML would retype it")
        #expect(emitted == YAMLScalar.quoteIfNeeded(raw))
        #expect(YAMLScalar.unquote(emitted) == raw)
    }

    /// Plain values still go bare — the unification must not churn every
    /// config in the world.
    @Test func yamlScalarLeavesAPlainValueAlone() {
        #expect(HermesFileService.yamlScalar("abc123") == "abc123")
    }

    /// P29 · The tab guard the line-break arm shipped without. A tab anywhere
    /// in a scalar makes PyYAML's scanner reject the row ("found character
    /// '\\t' that cannot start any token"), which discards the WHOLE
    /// config.yaml layer. `YAMLScalar.quoteIfNeeded` has had this arm all
    /// along (`YAMLScalar.swift:119`) and the KEY on the same emitted row goes
    /// through it, so before this fix one row quoted its key for a tab and not
    /// its value.
    ///
    /// The value is the only unsanitised half:
    /// `MCPServerEditorViewModel.swift:195,201` trims the key and passes the
    /// value raw, so leading, trailing and interior tabs all reach the writer.
    @Test(arguments: ["A\tB", "\ttrailing", "trailing\t"])
    func yamlScalarQuotesATabbedValue(_ value: String) throws {
        // Pure half: never emitted bare.
        let emitted = HermesFileService.yamlScalar(value)
        #expect(emitted != value, "a tabbed value was emitted bare")
        #expect(HermesFileService.unquote(emitted) == value, "the tab must round-trip")

        // Through the real writer, as an MCP `env:` VALUE — the reachable
        // path, and the one `MCPYAMLMapKeyP19Tests` only ever tested as a key.
        let (service, home) = try loadFixture()
        #expect(service.setMCPServerEnv(name: "remote_api", env: ["TOKEN": value]))
        let written = try readConfig(home)
        #expect(!written.contains("TOKEN: \(value)"))

        guard Self.pyYAMLAvailable else { return }
        #expect(Self.parses(written), "Hermes would discard the whole config.yaml layer")
        let readBack = Self.run(
            """
            import sys,yaml
            print(repr(yaml.safe_load(sys.stdin.read())['mcp_servers']['remote_api']['env']['TOKEN']))
            """,
            stdin: written
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        // PyYAML gives back exactly the string the user typed, tab included.
        // Python's `repr` escapes the tab, so the expectation does too.
        let expected = "'" + value.replacingOccurrences(of: "\t", with: "\\t") + "'"
        #expect(readBack == expected, "PyYAML read back \(readBack ?? "nil")")
    }

    // MARK: - Finding 3: BOM — the audit's consequence is NOT reachable here

    /// **NO-OP, with evidence.** The round-2 audit derived the BOM finding
    /// from the pure functions and concluded that a BOM'd config.yaml would
    /// hide its first section and get a duplicate appended. Through Scarf's
    /// actual read path it cannot: every text read in the app decodes with
    /// `String(data:encoding: .utf8)` (`ServerContext.readTextThrowing:426`,
    /// `GuardedTextFile:291`, `HermesFileService.readFileResult:2845`), and
    /// Foundation's UTF-8 decoder STRIPS a leading U+FEFF — so no matcher,
    /// parser or writer in the app ever sees one, and the BOM's 3 bytes are
    /// already dropped on the first write, with or without P19.
    ///
    /// What P19 fixes is the pure-function contract (see
    /// `HermesP19YAMLHardeningTests.bomDoesNotDuplicateTheFirstSection`):
    /// `GatewayConfigWriter` / `HermesYAML` / `trimYAMLLine` handle a BOM
    /// correctly when they are handed one, instead of relying on the read
    /// layer happening to have eaten it.
    ///
    /// This test pins the reachability claim, so a future read path that
    /// decodes `Data` by hand (and therefore DOES carry the BOM through)
    /// shows up here rather than as a mystery duplicate section.
    @Test func foundationStripsTheBOMBeforeAnyWriterSeesIt() throws {
        #expect(
            String(data: Data("\u{FEFF}a: b\n".utf8), encoding: .utf8)?
                .hasPrefix("\u{FEFF}") == false,
            "if Foundation ever stops stripping the BOM, the writers must carry it — they now can"
        )
        let (service, home) = try loadFixture(prefix: "\u{FEFF}")
        #expect(service.setMCPServerEnv(name: "remote_api", env: ["API_KEY": "abc"]))
        let written = try readConfig(home)
        #expect(written.contains("      API_KEY: abc"))
        guard Self.pyYAMLAvailable else { return }
        #expect(Self.block(written, "remote_api", "env") == "{'API_KEY': 'abc'}")
    }

    /// And the comparison boundary handles a BOM directly, so a BOM'd line
    /// handed to this file's matchers is the key they are looking for.
    @Test func trimYAMLLineStripsALeadingBOM() {
        #expect(HermesFileService.trimYAMLLine("\u{FEFF}mcp_servers:") == "mcp_servers:")
        #expect(HermesFileService.trimYAMLLine("  remote_api:  ") == "remote_api:")
    }
}
