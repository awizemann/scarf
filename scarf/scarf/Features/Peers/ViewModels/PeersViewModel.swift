import Foundation
import ScarfCore
import os

/// One asynchronous peer run Scarf started (or is tracking) this
/// session. Held in memory only: `hermes peer` has no "list my runs"
/// verb — the run id returned by `peer run` is the only handle, so the
/// rows live as long as the coordinator-cached view model does and are
/// re-queried on demand with `peer status`.
struct PeerRunRow: Identifiable, Sendable, Equatable {
    let id: String              // run_id
    let peer: String
    let profile: String?
    let idempotencyKey: String
    let startedAt: Date
    /// First line of the message that started it — enough to tell two
    /// rows apart without turning this into a transcript.
    let promptPreview: String
    var status: String
    var replayed: Bool
    var output: String?
    var error: String?
    var isBusy: Bool = false

    var target: String { HermesPeerCLI.target(peer: peer, profile: profile) }

    /// Terminal states hide Stop. Unknown/unrecognised statuses are
    /// treated as live — offering a Stop that the peer refuses is
    /// cheaper than hiding one the user needs.
    var isTerminal: Bool {
        ["completed", "succeeded", "failed", "error", "cancelled", "canceled", "stopped"]
            .contains(status.lowercased())
    }
}

/// Backing model for the Peers surface — the small native front end for
/// `hermes peer` (Hermes v0.21+).
///
/// Registry reads come from `config.yaml` (`bot_peers:`), never from
/// `hermes peer list`: the CLI's list output has no `--json` mode and
/// annotates each row with whether a key is set, which means resolving
/// the credential. Scarf reads the file instead and shows only
/// `name`/`url`/`note`. **No peer key is ever read or displayed.**
@Observable
final class PeersViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "PeersViewModel")
    let context: ServerContext
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.fileService = HermesFileService(context: context)
    }

    // MARK: - Registry

    var peers: [HermesBotPeer] = []
    var isLoading = false
    /// Nil when `config.yaml` was readable. Non-nil means the registry
    /// couldn't be read at all — distinct from "no peers registered".
    var loadError: String?

    @ObservationIgnored private var hasLoaded = false

    /// Selected peer name. Kept as a name (not an index) so a reload
    /// that reorders or drops entries can't silently retarget a send.
    var selectedPeerName: String?
    /// Optional named profile on a multiplexed peer → `<peer>/<agent>`.
    var profile: String = ""
    var composeText: String = ""

    var selectedPeer: HermesBotPeer? {
        guard let selectedPeerName else { return nil }
        return peers.first { $0.name == selectedPeerName }
    }

    private var currentTarget: String? {
        guard let peer = selectedPeer else { return nil }
        let trimmed = profile.trimmingCharacters(in: .whitespaces)
        return HermesPeerCLI.target(peer: peer.name, profile: trimmed.isEmpty ? nil : trimmed)
    }

    func load(force: Bool = false) {
        if !force, hasLoaded || isLoading { return }
        hasLoaded = true
        isLoading = true
        let ctx = context
        Task.detached { [weak self] in
            let yaml = HermesConfigReader.readRawConfig(context: ctx)
            let parsed = yaml.map(HermesBotPeersYAML.parse(yaml:))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.peers = parsed ?? []
                self.loadError = parsed == nil ? "Couldn't read config.yaml on this host." : nil
                if let selected = self.selectedPeerName,
                   !self.peers.contains(where: { $0.name == selected }) {
                    self.selectedPeerName = nil
                }
                if self.selectedPeerName == nil { self.selectedPeerName = self.peers.first?.name }
            }
        }
    }

    // MARK: - Transcript-free activity feed

    /// Last DM reply, shown inline under the compose field. Cleared on
    /// the next send. This is deliberately a single latest-reply slot,
    /// not a conversation: bot-to-bot chat is Bot Mode's surface.
    var lastReply: String?
    /// Transient status/error line for the header.
    var message: String?
    var errorMessage: String?
    /// Non-fatal stderr note from `peer run` (the peer doesn't advertise
    /// restart-durable replay). Shown as a caption, not an error.
    var durabilityNote: String?
    var isSending = false

    var runs: [PeerRunRow] = []

    // MARK: - Actions

    func sendDM() {
        guard let target = currentTarget else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // At send time, without an outcome: a peer DM is one synchronous
        // remote agent turn that can legitimately run for minutes.
        Analytics.record(.botPeerAction(action: .dmSent))
        isSending = true
        errorMessage = nil
        lastReply = nil
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            // One synchronous remote agent turn — legitimately minutes
            // long, so the CLI's own DM_TIMEOUT_S (600) is the bound
            // Scarf mirrors rather than cutting it short locally.
            let result = svc.runHermesCLISplit(
                args: HermesPeerCLI.dmArgs(target: target, message: text),
                timeout: 600
            )
            let parsed = HermesPeerCLI.parseDM(
                exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSending = false
                switch parsed {
                case .success(let dm):
                    self.composeText = ""
                    self.lastReply = dm.reply.isEmpty ? "(no reply)" : dm.reply
                    self.flash("Delivered to \(target)")
                case .failure(let failure):
                    log.warning("peer dm failed: \(failure.message, privacy: .public)")
                    self.errorMessage = failure.message
                }
            }
        }
    }

    func startRun() {
        guard let target = currentTarget else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        Analytics.record(.botPeerAction(action: .asyncRun))
        isSending = true
        errorMessage = nil
        durabilityNote = nil
        let preview = String(text.split(separator: "\n").first ?? "").prefix(120)
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            let result = svc.runHermesCLISplit(
                args: HermesPeerCLI.runArgs(target: target, message: text),
                timeout: 120
            )
            // Non-fatal: read it regardless of outcome, but only keep it
            // on the success path (a failure has its own message).
            let warning = HermesPeerCLI.durabilityWarning(inStderr: result.stderr)
            let parsed = HermesPeerCLI.parseRun(
                exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isSending = false
                switch parsed {
                case .success(let run):
                    self.composeText = ""
                    self.durabilityNote = warning
                    let row = PeerRunRow(
                        id: run.runID,
                        peer: run.peer,
                        profile: run.profile,
                        idempotencyKey: run.idempotencyKey,
                        startedAt: Date(),
                        promptPreview: String(preview),
                        status: run.status,
                        replayed: run.replayed,
                        output: nil,
                        error: nil
                    )
                    // A replayed run may already be tracked — replace
                    // rather than duplicate the same handle.
                    if let index = self.runs.firstIndex(where: { $0.id == row.id }) {
                        self.runs[index] = row
                    } else {
                        self.runs.insert(row, at: 0)
                    }
                    self.flash(run.replayed ? "Replayed \(run.runID)" : "Started \(run.runID)")
                case .failure(let failure):
                    log.warning("peer run failed: \(failure.message, privacy: .public)")
                    self.errorMessage = failure.message
                }
            }
        }
    }

    func refresh(_ run: PeerRunRow) {
        mutate(run) { HermesPeerCLI.statusArgs(target: $0.target, runID: $0.id) }
    }

    func stop(_ run: PeerRunRow) {
        mutate(run) { HermesPeerCLI.stopArgs(target: $0.target, runID: $0.id) }
    }

    /// `status` and `stop` share a payload shape and an update path — the
    /// only difference is the argv.
    private func mutate(_ run: PeerRunRow, args: @escaping (PeerRunRow) -> [String]) {
        guard let index = runs.firstIndex(where: { $0.id == run.id }), !runs[index].isBusy else { return }
        runs[index].isBusy = true
        errorMessage = nil
        let argv = args(run)
        let svc = fileService
        let log = logger
        Task.detached { [weak self] in
            let result = svc.runHermesCLISplit(args: argv, timeout: 60)
            let parsed = HermesPeerCLI.parseRunStatus(
                exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr
            )
            await MainActor.run { [weak self] in
                guard let self, let index = self.runs.firstIndex(where: { $0.id == run.id }) else { return }
                self.runs[index].isBusy = false
                switch parsed {
                case .success(let status):
                    self.runs[index].status = status.status
                    self.runs[index].output = status.output
                    self.runs[index].error = status.error
                case .failure(let failure):
                    log.warning("peer status/stop failed: \(failure.message, privacy: .public)")
                    self.errorMessage = failure.message
                }
            }
        }
    }

    func forget(_ run: PeerRunRow) {
        runs.removeAll { $0.id == run.id }
    }

    private func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }
}
