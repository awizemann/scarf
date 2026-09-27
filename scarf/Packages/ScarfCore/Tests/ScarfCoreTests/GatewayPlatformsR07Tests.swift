import Foundation
import Testing
@testable import ScarfCore

/// R07 (Hermes v0.21.5 audit): gateway status keys, multiplexer-served
/// profiles, the gateway `pgrep` pattern, and the ScarfGo webhook listing.
@Suite("Gateway & platforms R07")
struct GatewayPlatformsR07Tests {

    // MARK: - Fixtures from Hermes itself

    /// Written by Hermes's own `gateway.status.write_runtime_status` @
    /// v2026.9.24 into a scratch HERMES_HOME (a multiplexer serving `default`
    /// and `work`), with host fields (pid, argv, home) anonymised. Hermes's
    /// `profile_platforms_from_multiplexer(record, "work")` on this record
    /// returned `webhook` (mirrored from default), `telegram` (connected) and
    /// `discord` (fatal) — what the projection below must reproduce.
    static let multiplexerRecord = #"""
    {"pid": 4242, "kind": "hermes-gateway",
     "argv": ["/opt/hermes/.venv/bin/python", "-m", "hermes_cli.main", "gateway", "run"],
     "start_time": 179047382801, "hermes_home": "/home/u/.hermes",
     "gateway_state": "running", "exit_reason": null, "restart_requested": false, "active_agents": 0,
     "platforms": {
      "telegram": {"state": "connected", "error_code": null, "error_message": null, "needs_attention": false,
                   "retrying_since": null, "updated_at": "2026-09-27T01:50:28.351513+00:00",
                   "writer_pid": 4242, "writer_start_time": 179047382801},
      "discord": {"state": "fatal", "error_code": "auth_failed", "error_message": "Improper token has been passed.",
                  "updated_at": "2026-09-27T01:50:28.352304+00:00", "writer_pid": 4242, "writer_start_time": 179047382801},
      "slack": {"state": "retrying", "error_code": "network", "error_message": "Connection reset by peer",
                "updated_at": "2026-09-27T01:50:28.353002+00:00", "writer_pid": 4242, "writer_start_time": 179047382801},
      "webhook": {"state": "connected", "needs_attention": false, "retrying_since": null,
                  "listener_base": "http://127.0.0.1:8644", "updated_at": "2026-09-27T01:50:28.353661+00:00",
                  "writer_pid": 4242, "writer_start_time": 179047382801},
      "work:telegram": {"state": "connected", "error_code": null, "error_message": null, "needs_attention": false,
                        "retrying_since": null, "updated_at": "2026-09-27T01:50:28.354308+00:00",
                        "writer_pid": 4242, "writer_start_time": 179047382801},
      "work:discord": {"state": "fatal", "error_code": "auth_failed", "error_message": "Improper token has been passed.",
                       "updated_at": "2026-09-27T01:50:28.354955+00:00", "writer_pid": 4242, "writer_start_time": 179047382801}
     },
     "session_store": {"status": "unknown"}, "updated_at": "2026-09-27T01:50:28.354947+00:00",
     "code_sha": "f97608f178d1ffeca59860195ab7da295f7c8e5f", "code_version": "0.21.5",
     "served_profiles": ["default", "work"]}
    """#

    /// `hermes webhook list` @ v2026.9.24, captured from the real CLI
    /// (`python -m hermes_cli.main webhook list`, scratch HERMES_HOME with
    /// `platforms.webhook.enabled: true` and two `webhook subscribe` runs).
    /// Note the `Profile:` line, which the older transcribed fixtures lack.
    static let capturedWebhookList = """

      2 webhook subscription(s):

      ◆ deploys
        Notify on deploy events
        URL:     http://localhost:8644/webhooks/deploys
        Profile: default
        Events:  push, release
        Deliver: telegram

      ◆ alerts
        Agent-created subscription: alerts
        URL:     http://localhost:8644/webhooks/alerts
        Profile: default
        Events:  (all)
        Deliver: log

    """

    /// Same capture, no subscriptions.
    static let capturedEmptyWebhookList = """
      No dynamic webhook subscriptions.
      Create one with: hermes webhook subscribe <name>

    """

    private static func decode(_ json: String) throws -> GatewayState {
        try JSONDecoder().decode(GatewayState.self, from: Data(json.utf8))
    }

    // MARK: - S07-F1: PlatformState reads Hermes's keys

    @Test func platformStateReadsStateAndErrorMessage() throws {
        let state = try Self.decode(Self.multiplexerRecord)
        let plats = try #require(state.platforms)

        let telegram = try #require(plats["telegram"])
        #expect(telegram.isConnected)
        #expect(telegram.errorText == nil)

        let discord = try #require(plats["discord"])
        #expect(!discord.isConnected)
        #expect(discord.errorText == "Improper token has been passed.")

        // Retrying carries its reason; that is what the red dot shows.
        #expect(plats["slack"]?.errorText == "Connection reset by peer")
        #expect(plats["webhook"]?.isConnected == true)
    }

    @Test func fatalWithoutMessageFallsBackToCode() throws {
        let s = try JSONDecoder().decode(PlatformState.self, from: Data(#"{"state":"fatal","error_code":"auth_failed","error_message":null}"#.utf8))
        #expect(s.errorText == "auth_failed")
        let bare = try JSONDecoder().decode(PlatformState.self, from: Data(#"{"state":"fatal"}"#.utf8))
        #expect(bare.errorText == "fatal")
        // A disconnected platform with no message is not an error.
        let off = try JSONDecoder().decode(PlatformState.self, from: Data(#"{"state":"disconnected"}"#.utf8))
        #expect(off.errorText == nil)
        #expect(!off.isConnected)
    }

    @Test func legacyKeysStillDecode() throws {
        let up = try JSONDecoder().decode(PlatformState.self, from: Data(#"{"connected":true}"#.utf8))
        #expect(up.isConnected)
        let down = try JSONDecoder().decode(PlatformState.self, from: Data(#"{"connected":false,"error":"boom"}"#.utf8))
        #expect(!down.isConnected)
        #expect(down.errorText == "boom")
    }

    // MARK: - S07-F2: multiplexer-served profile

    @Test func servedProfileGetsItsPrefixedEntriesAndMirrors() throws {
        let data = HermesGatewayStateProjection.effectiveRecord(
            ownData: nil, rootData: Data(Self.multiplexerRecord.utf8), profile: "work")
        let state = try JSONDecoder().decode(GatewayState.self, from: try #require(data))
        let plats = try #require(state.platforms)
        // Exactly what Hermes's own `profile_platforms_from_multiplexer` returned.
        #expect(Set(plats.keys) == ["telegram", "discord", "webhook"])
        #expect(plats["telegram"]?.isConnected == true)
        #expect(plats["discord"]?.errorText == "Improper token has been passed.")
        #expect(plats["webhook"]?.isConnected == true)
        // The root's own slack entry is the DEFAULT profile's, not work's.
        #expect(plats["slack"] == nil)
        #expect(state.isRunning)
        #expect(state.pid == 4242)
    }

    @Test func unservedOrDefaultProfileKeepsItsOwnFile() {
        let own = Data(#"{"gateway_state":"stopped","updated_at":"2026-01-01T00:00:00+00:00"}"#.utf8)
        let root = Data(Self.multiplexerRecord.utf8)
        // Default profile: never projected.
        #expect(HermesGatewayStateProjection.effectiveRecord(ownData: own, rootData: root, profile: nil) == own)
        #expect(HermesGatewayStateProjection.effectiveRecord(ownData: own, rootData: root, profile: "default") == own)
        // A profile the root does not serve (every host below v2026.6.19 —
        // no `served_profiles` at all — looks the same).
        #expect(HermesGatewayStateProjection.effectiveRecord(ownData: own, rootData: root, profile: "other") == own)
        let preMultiplex = Data(#"{"gateway_state":"running","platforms":{"work:telegram":{"state":"connected"}}}"#.utf8)
        #expect(HermesGatewayStateProjection.effectiveRecord(ownData: nil, rootData: preMultiplex, profile: "work") == nil)
    }

    @Test func aNewerOwnFileWinsOverAStaleRoster() {
        // The profile has since started its own gateway: its file is newer.
        let own = Data(#"{"gateway_state":"running","updated_at":"2026-09-28T00:00:00+00:00","platforms":{}}"#.utf8)
        let out = HermesGatewayStateProjection.effectiveRecord(
            ownData: own, rootData: Data(Self.multiplexerRecord.utf8), profile: "work")
        #expect(out == own)
    }

    // MARK: - S15-F2 / S15-F5: the pgrep pattern

    /// Match with POSIX `regcomp(REG_EXTENDED)` — the engine `pgrep -f` uses.
    private static func ereMatches(_ pattern: String, _ line: String) -> Bool {
        var re = regex_t()
        guard regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB) == 0 else {
            Issue.record("pattern failed to compile: \(pattern)")
            return false
        }
        defer { regfree(&re) }
        return regexec(&re, line, 0, nil, 0) == 0
    }

    /// The three processes a macOS launchd install runs, as `ps` showed them
    /// on a live v0.21.5 host (paths shortened). Only the last is the gateway.
    static let py = "/Users/u/.hermes/hermes-agent/.venv/bin/python"
    static let osascriptWrapper = #"/usr/bin/osascript -e do shell script "exec \#(py) -m hermes_cli.stderr_timestamp --error-log /Users/u/.hermes/logs/gateway.error.log -- \#(py) -m hermes_cli.main gateway run --external-supervisor >> /Users/u/.hermes/logs/gateway.log 2>> /Users/u/.hermes/logs/gateway.error.log""#
    static let stderrWrapper = "\(py) -m hermes_cli.stderr_timestamp --error-log /Users/u/.hermes/logs/gateway.error.log -- \(py) -m hermes_cli.main gateway run --external-supervisor"
    static let realGateway = "\(py) -m hermes_cli.main gateway run --external-supervisor"

    @Test func defaultPatternMatchesOnlyTheRealGateway() {
        let p = HermesGatewayProcessMatch.pgrepPattern(profile: nil)
        #expect(Self.ereMatches(p, Self.realGateway))
        #expect(!Self.ereMatches(p, Self.osascriptWrapper), "osascript wrapper matched (S15-F5)")
        #expect(!Self.ereMatches(p, Self.stderrWrapper), "stderr_timestamp wrapper matched (S15-F5)")
        // Script form, systemd form, a path with spaces, and -p default.
        #expect(Self.ereMatches(p, "/usr/bin/python3 /home/u/.local/bin/hermes gateway run"))
        #expect(Self.ereMatches(p, "/home/u/.local/bin/hermes gateway run --replace"))
        #expect(Self.ereMatches(p, "hermes gateway run"))
        #expect(Self.ereMatches(p, "/Users/u/Library/Application Support/hermes/venv/bin/python -m hermes_cli.main gateway run"))
        #expect(Self.ereMatches(p, "hermes -p default gateway run"))
        // Python's argument-less switches before `-m` / the script.
        #expect(Self.ereMatches(p, "/usr/bin/python3 -u -m hermes_cli.main gateway run"))
        #expect(Self.ereMatches(p, "/usr/bin/python3 -I -B /home/u/.local/bin/hermes gateway run"))
        #expect(!Self.ereMatches(p, "/usr/bin/python3 -c import x -m hermes_cli.main gateway run"))
        // Not the gateway: other verbs, other profiles, lookalikes.
        #expect(!Self.ereMatches(p, "\(Self.py) -m hermes_cli.main gateway status"))
        #expect(!Self.ereMatches(p, "hermes acp"))
        #expect(!Self.ereMatches(p, "\(Self.py) -m hermes_cli.main --profile work gateway run"))
        #expect(!Self.ereMatches(p, "hermes -p work gateway run"))
        #expect(!Self.ereMatches(p, "tail -f /Users/u/.hermes/logs/gateway.log hermes gateway run"))
        #expect(!Self.ereMatches(p, "/bin/sh -c hermes gateway run"))
    }

    @Test func namedPatternMatchesOnlyThatProfile() {
        let p = HermesGatewayProcessMatch.pgrepPattern(profile: "work")
        // launchd / systemd (`_profile_arg` → `--profile work`), foreground.
        #expect(Self.ereMatches(p, "\(Self.py) -m hermes_cli.main --profile work gateway run --external-supervisor"))
        #expect(Self.ereMatches(p, "/usr/bin/python3 -m hermes_cli.main --profile work gateway run"))
        #expect(Self.ereMatches(p, "/home/u/.local/bin/hermes -p work gateway run"))
        #expect(Self.ereMatches(p, "hermes --profile=work gateway run"))
        #expect(Self.ereMatches(p, "hermes gateway run -p work"))
        // Never the default gateway, a sibling profile, or a prefix of the name.
        #expect(!Self.ereMatches(p, Self.realGateway))
        #expect(!Self.ereMatches(p, "hermes -p work-2 gateway run"))
        #expect(!Self.ereMatches(p, "hermes -p ops gateway run"))
        #expect(!Self.ereMatches(p, "hermes gateway run -p work-2"))
        // The launchd wrappers of a named profile.
        let wrapped = "\(Self.py) -m hermes_cli.stderr_timestamp --error-log x -- \(Self.py) -m hermes_cli.main --profile work gateway run"
        #expect(!Self.ereMatches(p, wrapped))
    }

    @Test func firstPIDSkipsBlankLines() {
        #expect(HermesGatewayProcessMatch.firstPID(inPgrepOutput: "\n 8550\n9000\n") == 8550)
        #expect(HermesGatewayProcessMatch.firstPID(inPgrepOutput: "") == nil)
    }

    #if os(macOS)
    /// The real `/usr/bin/pgrep`, against a process whose command line is a
    /// named-profile gateway's. `exec -a` sets argv[0] to the whole string,
    /// and `pgrep -f` matches the space-joined argv.
    @Test func livePgrepFindsANamedProfileGateway() throws {
        let marker = "r07\(UInt32.random(in: 100_000...999_999))"
        let fake = "/tmp/\(marker)/python -m hermes_cli.main --profile \(marker) gateway run"
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/bash")
        sleeper.arguments = ["-c", "exec -a '\(fake)' /bin/sleep 20"]
        try sleeper.run()
        defer { sleeper.terminate() }

        func pgrep(_ profile: String?) throws -> [Int32] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", HermesGatewayProcessMatch.pgrepPattern(profile: profile)]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.split(separator: "\n").compactMap { Int32($0) }
        }
        // Poll until bash has exec'd into the renamed process.
        var found = false
        for _ in 0..<100 where !found {
            found = try pgrep(marker).contains(sleeper.processIdentifier)
            if !found { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(found)
        #expect(try !pgrep(nil).contains(sleeper.processIdentifier),
                "a named-profile gateway read as the default profile's")
    }
    #endif

    // MARK: - S07-F5: ScarfGo webhook listing, real CLI output

    @Test func capturedWebhookListParses() throws {
        guard case .entries(let entries) = HermesWebhookList.listing(Self.capturedWebhookList) else {
            Issue.record("captured listing did not parse"); return
        }
        #expect(entries.map(\.name) == ["deploys", "alerts"])
        #expect(entries[0].description == "Notify on deploy events")
        #expect(entries[0].url == "http://localhost:8644/webhooks/deploys")
        #expect(entries[0].events == ["push", "release"])
        #expect(entries[0].deliver == "telegram")
        #expect(entries[1].events.isEmpty)
        #expect(entries[1].deliver == "log")
    }

    @Test func capturedEmptyListingIsEmptyNotAnError() {
        #expect(HermesWebhookList.listing(Self.capturedEmptyWebhookList) == .entries([]))
        #expect(HermesWebhookList.listing("") == .entries([]))
    }

    @Test func notEnabledAndGarbageAreDistinct() {
        #expect(HermesWebhookList.listing("  Webhook platform is not enabled.\n") == .notEnabled)
        #expect(HermesWebhookList.listing("Traceback (most recent call last):\n  boom\n") == .unparsed)
    }
}
