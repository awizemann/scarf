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
final class GatewayBehaviorViewModel {
    private static let logger = Logger(subsystem: "com.scarf", category: "GatewayBehavior")

    let platform: String
    let context: ServerContext
    let capabilities: HermesCapabilities
    /// Allowlist kind for this platform, or `nil` for platforms without
    /// an allowlist surface (Discord, Signal, etc. — `GatewayBehaviorSection`
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
    var gatewayRestartNotification: Bool = false

    var message: String?
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
        guard !isSaving else { return }
        isSaving = true
        message = nil

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
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespaces) }
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
            let outcome = await Task.detached { () -> String in
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
                        return "Failed to write allowlist to config.yaml"
                    }
                }
                // Step 2: scalar saves via `hermes config set`.
                if kv.isEmpty {
                    return "Allowlist saved — restart gateway to apply"
                }
                return PlatformSetupHelpers.saveForm(
                    context: ctx, envPairs: [:], configKV: kv
                )
            }.value

            guard let self else { return }
            self.isSaving = false
            self.message = outcome
            if outcome == "Failed to write allowlist to config.yaml" {
                Self.logger.warning("GatewayConfigWriter.saveList failed for \(platform, privacy: .public)")
                // A failure message is never auto-cleared — the user
                // dismisses it by saving again.
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.message = nil
            }
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
