import Testing
import Foundation
@testable import ScarfCore

/// W9 of the Hermes v0.21.0 parity cycle — the `hermes peer` surface.
///
/// Pinned against real Hermes source at the audited tag:
/// `hermes_cli/subcommands/peer.py` (`cmd_peer` dispatch :293-430,
/// `build_peer_parser` :443-540, `_load_peers`/`_save_peers`,
/// `_ensure_bot_chat`). Every JSON fixture below is the exact object
/// `cmd_peer` serializes on the corresponding branch, and every error
/// fixture is the exact sentence it writes to stderr.
@Suite struct HermesV021PeerParityTests {

    // MARK: - bot_peers registry (config.yaml)

    @Test func parsesBlockStyleBotPeersRegistry() {
        // The shape PyYAML dumps from `_save_peers`: `note` present only
        // when `--note` was given.
        let yaml = """
        model:
          default: sonnet
        bot_peers:
          spark:
            url: http://spark.lan:8377
            note: homelab box
          cloud:
            url: https://hermes.example.com
        """
        let peers = HermesBotPeersYAML.parse(yaml: yaml)
        #expect(peers.count == 2)
        // Sorted by name, matching `peer list`'s `sorted(peers)`.
        #expect(peers[0].name == "cloud")
        #expect(peers[0].url == "https://hermes.example.com")
        #expect(peers[0].note.isEmpty)
        #expect(peers[1].name == "spark")
        #expect(peers[1].url == "http://spark.lan:8377")
        #expect(peers[1].note == "homelab box")
    }

    @Test func absentOrEmptyRegistryYieldsNoPeers() {
        #expect(HermesBotPeersYAML.parse(yaml: "model:\n  default: sonnet\n").isEmpty)
        // Flow-style empty map — what a hand-cleared registry looks like.
        #expect(HermesBotPeersYAML.parse(yaml: "bot_peers: {}\n").isEmpty)
    }

    @Test func peerWithoutAURLIsDropped() {
        // `_resolve_peer_target` refuses a peer whose entry has no `url`
        // ("No peer named …"), so surfacing it would only offer actions
        // that cannot succeed.
        let yaml = """
        bot_peers:
          broken:
            note: someone hand-edited this
          good:
            url: http://good.lan:8377
        """
        let peers = HermesBotPeersYAML.parse(yaml: yaml)
        #expect(peers.map(\.name) == ["good"])
    }

    @Test func registryNeverExposesAKeyEvenIfOneIsHandWrittenIntoConfig() {
        // Hermes stores peer keys in ~/.hermes/.env, never config.yaml —
        // but a user could paste one in by hand. The model has nowhere to
        // put it, which is the point: it can't leak through Scarf.
        let yaml = """
        bot_peers:
          spark:
            url: http://spark.lan:8377
            key: sk-should-never-be-read
        """
        let peers = HermesBotPeersYAML.parse(yaml: yaml)
        #expect(peers.count == 1)
        #expect(peers[0].url == "http://spark.lan:8377")
        #expect(peers[0].note.isEmpty)
        // Only the env-var NAME is derivable, per `_peer_key_env`.
        #expect(peers[0].keyEnvName == "HERMES_PEER_SPARK_KEY")
    }

    @Test func keyEnvNameUppercasesAndUnderscoresHyphens() {
        // `_peer_key_env`: f"HERMES_PEER_{name.upper().replace('-','_')}_KEY"
        #expect(HermesBotPeer(name: "spark-2", url: "u").keyEnvName == "HERMES_PEER_SPARK_2_KEY")
    }

    // MARK: - argv

    @Test func argvMatchesTheArgparseSurface() {
        #expect(HermesPeerCLI.dmArgs(target: "spark", message: "hi")
            == ["peer", "dm", "spark", "hi", "--json"])
        #expect(HermesPeerCLI.runArgs(target: "spark/researcher", message: "hi")
            == ["peer", "run", "spark/researcher", "hi", "--json"])
        #expect(HermesPeerCLI.runArgs(target: "spark", message: "hi", idempotencyKey: "ticket-123")
            == ["peer", "run", "spark", "hi", "--idempotency-key", "ticket-123", "--json"])
        #expect(HermesPeerCLI.statusArgs(target: "spark", runID: "run_abc")
            == ["peer", "status", "spark", "run_abc", "--json"])
        #expect(HermesPeerCLI.stopArgs(target: "spark", runID: "run_abc")
            == ["peer", "stop", "spark", "run_abc", "--json"])
    }

    @Test func targetJoinsAProfileWithASlash() {
        // `_parse_target` splits on the first "/"; the bare form targets
        // the peer gateway's own launch profile.
        #expect(HermesPeerCLI.target(peer: "spark") == "spark")
        #expect(HermesPeerCLI.target(peer: "spark", profile: nil) == "spark")
        #expect(HermesPeerCLI.target(peer: "spark", profile: "") == "spark")
        #expect(HermesPeerCLI.target(peer: "spark", profile: "researcher") == "spark/researcher")
    }

    // MARK: - dm

    @Test func parsesDMPayload() {
        let stdout = #"{"peer": "spark", "profile": null, "session_id": "sess_1", "reply": "disk is fine"}"#
        let result = HermesPeerCLI.parseDM(exitCode: 0, stdout: stdout, stderr: "")
        guard case .success(let dm) = result else { Issue.record("expected success"); return }
        #expect(dm.peer == "spark")
        #expect(dm.profile == nil)          // JSON null, not the string "null"
        #expect(dm.sessionID == "sess_1")
        #expect(dm.reply == "disk is fine")
    }

    @Test func parsesDMPayloadWithAProfile() {
        let stdout = #"{"peer": "spark", "profile": "researcher", "session_id": "s", "reply": ""}"#
        let result = HermesPeerCLI.parseDM(exitCode: 0, stdout: stdout, stderr: "")
        guard case .success(let dm) = result else { Issue.record("expected success"); return }
        #expect(dm.profile == "researcher")
        // An empty reply is a legitimate success (the CLI's text mode
        // prints "(no reply)"), not a parse failure.
        #expect(dm.reply.isEmpty)
    }

    // MARK: - run

    @Test func parsesRunPayload() {
        let stdout = """
        {"peer": "spark", "profile": null, "session_id": "sess_1", "run_id": "run_abc123", \
        "status": "started", "idempotency_key": "peer-9f3c", "replayed": false}
        """
        let result = HermesPeerCLI.parseRun(exitCode: 0, stdout: stdout, stderr: "")
        guard case .success(let run) = result else { Issue.record("expected success"); return }
        #expect(run.runID == "run_abc123")
        #expect(run.status == "started")
        #expect(run.idempotencyKey == "peer-9f3c")
        #expect(!run.replayed)
    }

    @Test func parsesReplayedRun() {
        // Same idempotency key hitting an existing run: the peer replays
        // rather than starting a second one.
        let stdout = """
        {"peer": "spark", "profile": null, "session_id": "sess_1", "run_id": "run_abc123", \
        "status": "running", "idempotency_key": "ticket-123", "replayed": true}
        """
        let result = HermesPeerCLI.parseRun(exitCode: 0, stdout: stdout, stderr: "")
        guard case .success(let run) = result else { Issue.record("expected success"); return }
        #expect(run.replayed)
        #expect(run.idempotencyKey == "ticket-123")
    }

    /// THE gotcha of this work package: `peer run` writes a warning to
    /// stderr on the ordinary happy path — whenever the peer doesn't
    /// advertise `features.runs_idempotency.durable`, which includes
    /// every peer too old to expose `/v1/capabilities` at all. Judging
    /// success by "stderr is empty" would break `run` against most real
    /// peers.
    @Test func durabilityWarningOnStderrIsNotAFailure() {
        let stderr = """
        Warning: this peer does not advertise restart-durable run replay; keep the run ID \
        and avoid blind retries after a gateway restart.
        """
        let stdout = """
        {"peer": "spark", "profile": null, "session_id": "s", "run_id": "run_abc123", \
        "status": "started", "idempotency_key": "peer-1", "replayed": false}
        """
        let result = HermesPeerCLI.parseRun(exitCode: 0, stdout: stdout, stderr: stderr)
        guard case .success(let run) = result else { Issue.record("expected success"); return }
        #expect(run.runID == "run_abc123")

        let warning = HermesPeerCLI.durabilityWarning(inStderr: stderr)
        #expect(warning?.contains("restart-durable run replay") == true)
        #expect(HermesPeerCLI.durabilityWarning(inStderr: "") == nil)
    }

    // MARK: - status / stop

    @Test func parsesRunStatusWithOutput() {
        // `{peer, profile}` merged over the peer's raw /v1/runs/<id> body.
        let stdout = #"{"peer": "spark", "profile": null, "status": "completed", "output": "all good"}"#
        let result = HermesPeerCLI.parseRunStatus(exitCode: 0, stdout: stdout, stderr: "")
        guard case .success(let status) = result else { Issue.record("expected success"); return }
        #expect(status.status == "completed")
        #expect(status.output == "all good")
        #expect(status.error == nil)
        #expect(status.runID == nil)   // the CLI doesn't inject it
    }

    @Test func parsesRunStatusWithAFailedRun() {
        // A run that FAILED is a successful CLI invocation (exit 0) whose
        // payload carries the peer's error — distinct from the CLI being
        // unable to reach the peer.
        let stdout = #"{"peer": "spark", "profile": null, "status": "failed", "error": "tool crashed"}"#
        let result = HermesPeerCLI.parseRunStatus(exitCode: 0, stdout: stdout, stderr: "")
        guard case .success(let status) = result else { Issue.record("expected success"); return }
        #expect(status.status == "failed")
        #expect(status.error == "tool crashed")
    }

    @Test func statusWithoutAStatusKeyReadsAsUnknown() {
        // Mirrors the text mode's `result.get('status', 'unknown')`.
        let result = HermesPeerCLI.parseRunStatus(
            exitCode: 0, stdout: #"{"peer": "spark", "profile": null}"#, stderr: ""
        )
        guard case .success(let status) = result else { Issue.record("expected success"); return }
        #expect(status.status == "unknown")
    }

    @Test func parsesStopPayloadThroughTheSameShape() {
        // `stop` emits the identical `{peer, profile, **result}` object.
        let result = HermesPeerCLI.parseRunStatus(
            exitCode: 0,
            stdout: #"{"peer": "spark", "profile": "researcher", "status": "stopped"}"#,
            stderr: ""
        )
        guard case .success(let status) = result else { Issue.record("expected success"); return }
        #expect(status.status == "stopped")
        #expect(status.profile == "researcher")
    }

    // MARK: - exit codes

    @Test func exitTwoIsAUsageError() {
        // e.g. `_parse_target` raising on a bad profile name, or an empty
        // message.
        let result = HermesPeerCLI.parseDM(
            exitCode: 2, stdout: "", stderr: "Message required (argument or stdin).\n"
        )
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.kind == .usage)
        #expect(failure.message == "Message required (argument or stdin).")
    }

    @Test func exitOneIsADeliveryError() {
        let result = HermesPeerCLI.parseRun(
            exitCode: 1,
            stdout: "",
            stderr: "Could not reach peer 'spark': <urlopen error [Errno 61] Connection refused>\n"
        )
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.kind == .delivery)
        #expect(failure.message.contains("Connection refused"))
    }

    /// The other named gotcha: an HTTP 400 out of `_ensure_bot_chat`
    /// becomes a RuntimeError whose sentence tells the user the peer's
    /// hermes-agent is too old, and names the PATCH remedy. It must
    /// reach the UI verbatim — a paraphrase throws the remedy away.
    @Test func peerTooOldRuntimeErrorSurfacesVerbatim() {
        let stderr = """
        Peer 'spark': Peer already has a 'Bot Chat' session but it is hidden and the peer's \
        gateway is too old to expose hidden sessions to this lookup (HTTP 400: bad title). \
        Update the peer's hermes-agent, or unhide the session there: PATCH /api/sessions/<id> {"hidden": false}.
        """
        let result = HermesPeerCLI.parseDM(exitCode: 1, stdout: "", stderr: stderr + "\n")
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.kind == .delivery)
        #expect(failure.message == stderr)
    }

    @Test func missingKeyErrorNamesTheEnvVariableVerbatim() {
        let stderr = """
        No API key for peer 'spark'. Set it: hermes peer add spark --url <url> --key <key> \
        (or add HERMES_PEER_SPARK_KEY=<key> to ~/.hermes/.env)
        """
        let result = HermesPeerCLI.parseDM(exitCode: 1, stdout: "", stderr: stderr)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.message == stderr)
    }

    @Test func aFailureDropsTheDurabilityWarningFromItsMessage() {
        // `run` can emit the warning AND then fail for an unrelated
        // reason; the warning is noise in that message.
        let stderr = """
        Warning: this peer does not advertise restart-durable run replay; keep the run ID and avoid blind retries after a gateway restart.
        Peer 'spark' rejected the request (HTTP 503): upstream unavailable
        """
        let result = HermesPeerCLI.parseRun(exitCode: 1, stdout: "", stderr: stderr)
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.message == "Peer 'spark' rejected the request (HTTP 503): upstream unavailable")
    }

    @Test func transportFailureIsLocalNotDelivery() {
        // `runHermesCLISplit` returns -1 with an empty stdout when the
        // binary is missing or the SSH transport fails.
        let result = HermesPeerCLI.parseRun(
            exitCode: -1, stdout: "", stderr: "hermes binary not found"
        )
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.kind == .local)
    }

    @Test func cleanExitWithUnparsableOutputIsALocalFailure() {
        // A run payload with no `run_id` is unusable — the CLI itself
        // exits 1 in that case, but Scarf must not synthesize a handle if
        // the shape ever changes.
        let result = HermesPeerCLI.parseRun(
            exitCode: 0, stdout: #"{"peer": "spark", "status": "started"}"#, stderr: ""
        )
        guard case .failure(let failure) = result else { Issue.record("expected failure"); return }
        #expect(failure.kind == .local)

        let empty = HermesPeerCLI.parseDM(exitCode: 0, stdout: "", stderr: "")
        guard case .failure(let emptyFailure) = empty else { Issue.record("expected failure"); return }
        #expect(emptyFailure.kind == .local)
    }

    // MARK: - capability gating

    @Test func peerSurfaceIsHiddenBelowV021() {
        // The Peers sidebar entry is gated on exactly this flag, so a
        // pre-v0.21 host never sees a surface whose every verb would fail
        // at argparse.
        #expect(!HermesCapabilities.empty.hasPeerRunCommands)
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.20.6 (2026.8.27)").hasPeerRunCommands)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)").hasPeerRunCommands)
    }
}
