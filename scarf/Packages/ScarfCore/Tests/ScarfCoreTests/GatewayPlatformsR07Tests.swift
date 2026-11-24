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

    // MARK: - gh#154: v0.23 `-c` launchers

    /// `_launcher_script("hermes", Path("/opt/hermes-agent"), None)` as
    /// generated from the tagged v0.23.4 source (identical at v0.23.0), with
    /// the long `_hermes_closure_repair` body cut down; head and tail verbatim.
    static let launcherSource = #"""
import os, re, sys
import contextlib, hashlib, io, pathlib, shutil, subprocess
os.environ.pop('PYTHONHOME', None)
os.environ.pop('PYTHONPATH', None)
sys.path.insert(0, '/opt/hermes-agent')
def _hermes_closure_repair():
    import contextlib, hashlib, io, shutil, subprocess
    from pathlib import Path
    root = Path('/opt/hermes-agent')
    git = root / '.git'
    raise SystemExit(1)
if sys.argv[1:2] == ['--print-runtime-command']:
    sys.dont_write_bytecode = True
    from pathlib import Path
    try:
        from hermes_cli import _early_recovery
    except Exception as exc:
        if _hermes_closure_repair() or not isinstance(exc, ImportError):
            raise
        _early_recovery = None  # a tree without the repair: the imports below report real damage
    if _early_recovery is not None and _early_recovery.restore_interrupted_pull(Path('/opt/hermes-agent')):
        _early_recovery.relaunch_after_restore()
    from hermes_constants import get_default_hermes_root
    os.environ['HERMES_HOME'] = os.environ.get('HERMES_HOME') or str(get_default_hermes_root())
    from hermes_cli._launchers import print_runtime_command
    print_runtime_command(Path('/opt/hermes-agent'), sys.argv[2:])
    sys.exit(0)
sys._hermes_pin_default_home = True
try:
    import hermes_bootstrap
except Exception:
    _hermes_closure_repair()
    raise
if not os.environ.get('HERMES_HOME'):
    from hermes_constants import get_default_hermes_root
    os.environ['HERMES_HOME'] = str(get_default_hermes_root())
if sys.argv[1:2] == ['--run-module']:
    import runpy
    if len(sys.argv) < 3: sys.exit('hermes: --run-module needs a module')
    module = sys.argv.pop(2)
    del sys.argv[1]
    runpy.run_module(module, run_name='__main__', alter_sys=True)
    sys.exit(0)
from hermes_cli.main import main
sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?$', '', sys.argv[0])
sys.exit(main())
"""#
    /// The same launcher minted for `hermes-acp` (`ENTRY_POINTS`, `_launchers.py:107-110`).
    static let acpLauncherSource = launcherSource.replacingOccurrences(
        of: "from hermes_cli.main import main", with: "from acp_adapter.entry import main")
    /// `runtime_command(..., ["gateway", "run"])` @ v0.23.4, generated.
    static let runtimeSource = "import os, sys, runpy; os.environ.pop('PYTHONHOME', None); os.environ.pop('PYTHONPATH', None); os.environ.pop('VIRTUAL_ENV', None); sys.path.insert(0, '/opt/hermes-agent'); sys._hermes_pin_default_home = True; import hermes_bootstrap; os.environ.get('HERMES_HOME') or os.environ.__setitem__('HERMES_HOME', str(__import__('hermes_constants').get_default_hermes_root())); runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)"
    /// `posix_launcher("hermes", "hermes_cli.main:main", …)`'s `-c` program.
    static let dockerSource = "import os, site, sys; sys.argv[0]='hermes'; site.addsitedir(os.environ['HERMES_SITE']); from hermes_cli.main import main; sys.exit(main())"
    static let storePy = "/Users/u/.hermes/store/python/3.11/bin/python3"

    /// `pgrep -f` sees argv joined by spaces, newlines kept.
    static func launched(_ source: String, _ args: String, switch sw: String = "-I") -> String {
        "\(storePy) \(sw) -c \(source) \(args)"
    }

    @Test func v023LaunchersMatchTheirOwnProfileOnly() {
        let def = HermesGatewayProcessMatch.pgrepPattern(profile: nil)
        let ops = HermesGatewayProcessMatch.pgrepPattern(profile: "ops")
        let src = Self.launcherSource
        // Default profile: bin/hermes, runtime_command, Docker -P.
        #expect(Self.ereMatches(def, Self.launched(src, "gateway run")))
        #expect(Self.ereMatches(def, Self.launched(src, "gateway run --replace")))
        #expect(Self.ereMatches(def, Self.launched(Self.runtimeSource, "gateway run")))
        #expect(Self.ereMatches(def, Self.launched(Self.dockerSource, "gateway run", switch: "-P")))
        #expect(!Self.ereMatches(def, Self.launched(src, "-p ops gateway run")))
        // Named profile, every flag spelling and position.
        #expect(Self.ereMatches(ops, Self.launched(src, "-p ops gateway run")))
        #expect(Self.ereMatches(ops, Self.launched(src, "--profile=ops gateway run")))
        #expect(Self.ereMatches(ops, Self.launched(src, "--profile ops gateway run --external-supervisor")))
        #expect(Self.ereMatches(ops, Self.launched(src, "gateway run -p ops")))
        #expect(Self.ereMatches(ops, Self.launched(Self.runtimeSource, "-p ops gateway run")))
        #expect(Self.ereMatches(ops, Self.launched(Self.dockerSource, "-p ops gateway run", switch: "-P")))
        #expect(!Self.ereMatches(ops, Self.launched(src, "gateway run")))
        #expect(!Self.ereMatches(ops, Self.launched(src, "-p work gateway run")))
        #expect(!Self.ereMatches(ops, Self.launched(src, "gateway run -p ops-2")))
    }

    @Test func v023LaunchersRefuseLookalikes() {
        for profile in [nil, "ops"] as [String?] {
            let p = HermesGatewayProcessMatch.pgrepPattern(profile: profile)
            let flag = profile == nil ? "" : "-p ops "
            let real = Self.launched(Self.launcherSource, "\(flag)gateway run")
            // A watcher whose own -c program carries the launcher argv.
            #expect(!Self.ereMatches(p, "/usr/bin/python3 -c import time; time.sleep(9) \(real)"))
            #expect(!Self.ereMatches(p, "/usr/bin/python3 -I -c import os, sys; os.execv(sys.argv[1], sys.argv[1:]) \(real)"))
            // The same launcher, other entry points / verbs.
            #expect(!Self.ereMatches(p, Self.launched(Self.acpLauncherSource, "\(flag)gateway run")))
            #expect(!Self.ereMatches(p, Self.launched(Self.launcherSource, "--run-module hermes_cli.stderr_timestamp -- \(flag)gateway run")))
            #expect(!Self.ereMatches(p, Self.launched(Self.launcherSource, "\(flag)gateway status")))
            #expect(!Self.ereMatches(p, Self.launched(Self.launcherSource, "\(flag)chat")))
            #expect(!Self.ereMatches(p, Self.launched(
                Self.runtimeSource.replacingOccurrences(of: "'hermes_cli.main'", with: "'hermes_cli.stderr_timestamp'"),
                "-- \(flag)gateway run")))
            #expect(!Self.ereMatches(p, Self.launched(
                Self.dockerSource.replacingOccurrences(of: "hermes_cli.main", with: "acp_adapter.entry"),
                "\(flag)gateway run", switch: "-P")))
            // The SSH probe's own shell.
            #expect(!Self.ereMatches(p, "bash -c pgrep -f '\(p)'"))
            #expect(!p.contains("'"))
        }
    }

    @Test func v023LauncherLineAsPsPrintsIt() {
        let shown = Self.launched(Self.launcherSource, "gateway run").replacingOccurrences(of: "\n", with: "?")
        #expect(HermesGatewayProcessMatch.commandLineIsGateway(shown, profile: nil))
        #expect(HermesGatewayProcessMatch.commandLineIsGateway(shown, profile: "ops"))
        let flagged = Self.launched(Self.launcherSource, "-p ops gateway run").replacingOccurrences(of: "\n", with: "?")
        #expect(HermesGatewayProcessMatch.commandLineIsGateway(flagged, profile: "ops"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway(flagged, profile: "work"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway(flagged, profile: nil))
        let acp = Self.launched(Self.acpLauncherSource, "gateway run").replacingOccurrences(of: "\n", with: "?")
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway(acp, profile: nil))
        // macOS `ps -ww -o command=` prints a newline as `\012`.
        let mac = Self.launched(Self.launcherSource, "-p ops gateway run").replacingOccurrences(of: "\n", with: #"\012"#)
        #expect(HermesGatewayProcessMatch.commandLineIsGateway(mac, profile: "ops"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway(mac, profile: nil))
    }

    @Test func firstPIDSkipsBlankLines() {
        #expect(HermesGatewayProcessMatch.firstPID(inPgrepOutput: "\n 8550\n9000\n") == 8550)
        #expect(HermesGatewayProcessMatch.firstPID(inPgrepOutput: "") == nil)
    }

    // MARK: - `gateway.pid` fallback (a named profile's gateway with no `-p`)

    /// The record `_build_pid_record` writes (`gateway/status.py:677-684` @
    /// v2026.9.24), key set checked against a live `~/.hermes/gateway.pid`.
    static func pidRecord(pid: Int, home: String, kind: String = "hermes-gateway") -> Data {
        Data(#"{"pid": \#(pid), "kind": "\#(kind)", "argv": ["/x/python", "-m", "hermes_cli.main", "gateway", "run"], "start_time": 1, "hermes_home": "\#(home)"}"#.utf8)
    }

    @Test func pidFileRecordIsReadForItsOwnProfileOnly() {
        let work = Self.pidRecord(pid: 888, home: "/home/u/.hermes/profiles/work")
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: work, profile: "work") == 888)
        // Another profile's (or the root's) record is not this profile's.
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: work, profile: "ops") == nil)
        let root = Self.pidRecord(pid: 777, home: "/home/u/.hermes")
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: root, profile: "work") == nil)
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: root, profile: nil) == 777)
        // Not a gateway record, garbage, a bare pid (Hermes accepts that too).
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: Self.pidRecord(pid: 5, home: "/home/u/.hermes/profiles/work", kind: "other"), profile: "work") == nil)
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: Data("nope".utf8), profile: "work") == nil)
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: Data("4321\n".utf8), profile: "work") == 4321)
        #expect(HermesGatewayProcessMatch.pid(fromPidFile: Data("-1".utf8), profile: "work") == nil)
    }

    @Test func pidFileCommandLineCheckRefusesAStalePid() {
        // A gateway started with HERMES_HOME in its environment: no `-p`.
        #expect(HermesGatewayProcessMatch.commandLineIsGateway(Self.realGateway, profile: "work"))
        #expect(HermesGatewayProcessMatch.commandLineIsGateway(
            "\(Self.py) -m hermes_cli.main --profile work gateway run", profile: "work"))
        // The PID now belongs to something else, or to a wrapper, or to
        // another profile's flagged gateway.
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway("/usr/bin/vim notes.txt", profile: "work"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway(Self.osascriptWrapper, profile: "work"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway("hermes -p ops gateway run", profile: "work"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway("\(Self.py) -m hermes_cli.main gateway status", profile: "work"))
        // The root gateway stated explicitly, or a trailing flag for another
        // profile, is not an unflagged gateway.
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway("hermes -p default gateway run", profile: "work"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway("hermes gateway run -p ops", profile: "work"))
        #expect(!HermesGatewayProcessMatch.commandLineIsGateway("hermes --profile=ops gateway run", profile: "work"))
    }

    @Test func procStatStartTimeIsField22() {
        // A real-shaped /proc/<pid>/stat line; the comm contains ") (".
        let fields3to22 = (3...22).map { $0 == 22 ? "987654" : "\($0)" }.joined(separator: " ")
        let stat = "4242 (py) (thon) \(fields3to22) 23 24\n"
        #expect(HermesGatewayProcessMatch.procStatStartTime(stat) == 987654)
        #expect(HermesGatewayProcessMatch.procStatStartTime("garbage") == nil)
        #expect(HermesGatewayProcessMatch.startTime(fromPidFile: Self.pidRecord(pid: 1, home: "/h")) == 1)
        #expect(HermesGatewayProcessMatch.startTime(fromPidFile: Data("12".utf8)) == nil)
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
