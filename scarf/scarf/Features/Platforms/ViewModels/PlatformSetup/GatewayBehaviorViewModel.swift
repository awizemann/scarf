import Foundation
import ScarfCore
import os

/// View-model for the v0.13 Messaging Gateway behavior subsection composed
/// into each per-platform setup view. Owns the four v0.13 controls
/// (allowlist + three behavior toggles) so the existing per-platform VMs
/// don't grow another set of fields.
///
/// Capability-gated. Pre-v0.13 hosts skip the entire subsection (the
/// owning view returns `EmptyView` when none of the v0.13 flags is on),
/// so this VM never has its `save()` called against a host that can't
/// honor it.
@Observable
@MainActor
final class GatewayBehaviorViewModel: OutcomeMessageHosting {
    private static let logger = Logger(subsystem: "com.scarf", category: "GatewayBehavior")

    let platform: String
    let context: ServerContext
    let capabilities: HermesCapabilities
    /// Allowlist kind for this platform, or `nil` for platforms without
    /// an allowlist surface (Signal, Google Chat, etc. — `GatewayBehaviorSection`
    /// short-circuits before instantiating this VM in that case, but the
    /// field is `nil` for safety).
    let kind: GatewayAllowlistKind?

    // Allowlist
    var items: [String] = []

    // Behavior toggles.
    //
    // `busyAckEnabled` is GLOBAL: Hermes reads only `display.busy_ack_enabled`
    // (gateway/run.py bridges it to HERMES_GATEWAY_BUSY_ACK_ENABLED); the
    // per-platform `gateway.platforms.<p>.busy_ack_enabled` key Scarf used
    // to write was never read. The toggle is surfaced in each platform's
    // setup view for discoverability but edits apply gateway-wide.
    var busyAckEnabled: Bool = true
    // Hermes's own default is TRUE (`gateway/config.py` `PlatformConfig
    // .gateway_restart_notification: bool = True`, unchanged v2026.8.31 →
    // v2026.9.7). Scarf's `false` made the pre-load form — and any platform
    // with no key in config.yaml — render OFF while the host pinged on every
    // restart; saving from that form then wrote the `false` the user never
    // asked for. v0.21.1 audit B5.
    var gatewayRestartNotification: Bool = true

    var message: String?
    /// Outcome of `message` (GW-F4) — the save bar's colour, glyph and
    /// VoiceOver announcement come from this, never from the prose.
    var messageIsFailure = false
    /// P54b: the third seal state — an exit-0 run that proved nothing.
    var messageIsUnconfirmed = false
    var isSaving: Bool = false

    init(
        platform: String,
        capabilities: HermesCapabilities,
        context: ServerContext = .local
    ) {
        self.platform = platform
        self.capabilities = capabilities
        self.context = context
        self.kind = GatewayAllowlistKind.kind(for: platform)
    }

    /// Hydrate from `~/.hermes/config.yaml`. Called from the section's
    /// `.onAppear`. Empty when the platform has no `gateway:` block in
    /// the file — defaults match v0.13 server-side defaults so the form
    /// looks identical to a fresh-install host.
    func load() {
        let ctx = context
        let platform = platform
        let kind = kind
        isLoading = true
        // `loadConfig()` is an SFTP read on a remote host. Detached, then
        // committed on MainActor — the same posture `save()` now takes.
        Task { [weak self] in
            let snapshot = await Task.detached {
                () -> (items: [String], busyAck: Bool, restartNotification: Bool) in
                let cfg = HermesFileService(context: ctx).loadConfig()
                let block = cfg.gatewayPlatforms[platform] ?? .empty
                var items: [String] = []
                if let kind {
                    switch kind {
                    case .channels: items = block.allowedChannels
                    case .chats:    items = block.allowedChats
                    case .rooms:    items = block.allowedRooms
                    }
                }
                return (items, cfg.displayBusyAckEnabled, block.gatewayRestartNotification)
            }.value
            guard let self else { return }
            // Never clobber the form under a save in flight — the values the
            // user is committing must not be replaced by the pre-save disk
            // copy this read started from.
            guard !self.isSaving else { self.isLoading = false; return }
            self.items = snapshot.items
            self.busyAckEnabled = snapshot.busyAck
            self.gatewayRestartNotification = snapshot.restartNotification
            self.isLoading = false
        }
    }

    /// True while the initial config read is in flight.
    private(set) var isLoading: Bool = false

    /// Persist edits in two phases:
    ///
    /// 1. **Allowlist write** via `GatewayConfigWriter.saveList` — direct
    ///    YAML edit, since `hermes config set` can't write list values.
    ///    Skipped when the platform has no `kind` (no allowlist surface)
    ///    or the host doesn't advertise `hasGatewayAllowlists`.
    /// 2. **Scalar saves** via `PlatformSetupHelpers.saveForm` for the
    ///    behavior toggles, each gated on its own capability flag. Busy
    ///    ack writes the GLOBAL `display.busy_ack_enabled` — the only key
    ///    Hermes reads. (The old per-platform busy-ack key and the
    ///    `slash_command_notice_ttl_seconds` key were never read by any
    ///    Hermes version and are no longer written.)
    func save() {
        // `!isLoading` too: the form renders this VM's DEFAULTS until the
        // detached load lands, so a save from there would write them over
        // whatever config.yaml actually holds.
        guard !isSaving, !isLoading else { return }
        isSaving = true
        dismissMessage()

        // Step 2's key set is computed on MainActor (it reads the form), the
        // I/O below is not.
        var configKV: [String: String] = [:]
        if capabilities.hasGatewayBusyAckToggle {
            configKV["display.busy_ack_enabled"] =
                PlatformSetupHelpers.envBool(busyAckEnabled)
        }
        if capabilities.hasGatewayRestartNotification {
            // TOP-LEVEL `<platform>.gateway_restart_notification`, not
            // `gateway.platforms.<platform>.…`. Hermes reads the top-level
            // path, and so does Scarf's own parser
            // (`HermesConfig+YAML.swift:422` composes `"\(platform)."` +
            // the key); `GatewayConfigWriter` documents the same shape.
            // The old nested key was a silent no-op: the toggle wrote a
            // path nobody has ever read, and the reader then contradicted
            // it on the next load (go/no-go blocking condition 7, A5-HIGH).
            //
            // No migrate-on-read is needed — the bogus key was never read
            // by Hermes or by Scarf, so there is no stored value to
            // rescue; it is left in place as a harmless unknown key rather
            // than issuing a second `config unset` round-trip on every save.
            configKV[Self.restartNotificationKey(platform: platform, capabilities: capabilities)] =
                PlatformSetupHelpers.envBool(gatewayRestartNotification)
        }

        let ctx = context
        let platform = platform
        let listKey = (capabilities.hasGatewayAllowlists ? kind?.yamlKey : nil)
        // `.whitespacesAndNewlines`, not `.whitespaces`: a channel id
        // pasted with a trailing newline (or a whole multi-line paste)
        // reached `GatewayConfigWriter` with the break intact, which cannot
        // be written as one YAML row. Interior breaks still make the writer
        // refuse the whole save rather than emit a document PyYAML rejects.
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let kv = configKV

        // BOTH steps are I/O — a direct YAML rewrite (SCP round-trip on
        // remote) and one `hermes config set` process per key. Running them
        // inline froze the sheet for the whole save, and the `isSaving` flag
        // that guards the button was set and cleared inside the same
        // synchronous run (set, `defer`-cleared, never yielding), so it could
        // never render. The old step-1 comment claiming the write was
        // "detached so the SCP round-trip doesn't block MainActor" described
        // code that did not exist; it does now.
        Task { [weak self] in
            let outcome = await Task.detached { () -> PlatformSetupHelpers.SaveOutcome in
                // Step 1: list write via direct YAML edit — `hermes config
                // set` can't write list values.
                if let listKey {
                    let ok = GatewayConfigWriter.saveList(
                        context: ctx,
                        platform: platform,
                        key: listKey,
                        items: trimmedItems
                    )
                    if !ok {
                        return .failure(String(localized: "Failed to write allowlist to config.yaml"))
                    }
                }
                // Step 2: scalar saves via `hermes config set`.
                if kv.isEmpty {
                    return .success(String(localized: "Allowlist saved — restart gateway to apply"))
                }
                return PlatformSetupHelpers.saveForm(
                    context: ctx, envPairs: [:], configKV: kv
                )
            }.value

            guard let self else { return }
            self.isSaving = false
            // GW-F4: the outcome is now a stored fact rather than a string
            // comparison against one particular failure sentence, so a
            // `saveForm` refusal (".env"/`config set`) is treated as a
            // failure here too instead of auto-clearing like a success.
            // `applySaveOutcome` owns the "failures never auto-clear" rule.
            if outcome.isFailure {
                Self.logger.warning("Gateway behaviour save failed for \(platform, privacy: .public): \(outcome.text, privacy: .public)")
            }
            self.applySaveOutcome(outcome)
        }
    }

    /// The `hermes config set` key for the restart-notification toggle.
    /// Factored out so a test can assert the PATH without running the CLI —
    /// the nested `gateway.platforms.<p>.…` form this replaced was a silent
    /// no-op that survived precisely because nothing pinned the key.
    nonisolated static func restartNotificationKey(
        platform: String,
        capabilities: HermesCapabilities
    ) -> String {
        let segment = ConfigDottedKeySegment.escaped(platform, capabilities: capabilities)
        return "\(segment).gateway_restart_notification"
    }

}
