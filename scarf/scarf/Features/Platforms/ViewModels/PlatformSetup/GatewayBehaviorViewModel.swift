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
        let cfg = HermesFileService(context: context).loadConfig()
        let block = cfg.gatewayPlatforms[platform] ?? .empty
        if let kind {
            switch kind {
            case .channels: items = block.allowedChannels
            case .chats:    items = block.allowedChats
            case .rooms:    items = block.allowedRooms
            }
        } else {
            items = []
        }
        busyAckEnabled              = cfg.displayBusyAckEnabled
        gatewayRestartNotification  = block.gatewayRestartNotification
    }

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
        isSaving = true
        defer {
            isSaving = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.message = nil
            }
        }

        // Step 1: list write via direct YAML edit. Detached so the SCP
        // round-trip on remote hosts doesn't block MainActor — local
        // writes are still cheap, but the same posture works for both.
        if let kind, capabilities.hasGatewayAllowlists {
            let trimmed = items
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let ok = GatewayConfigWriter.saveList(
                context: context,
                platform: platform,
                key: kind.yamlKey,
                items: trimmed
            )
            if !ok {
                Self.logger.warning("GatewayConfigWriter.saveList failed for \(self.platform, privacy: .public)")
                message = "Failed to write allowlist to config.yaml"
                return
            }
        }

        // Step 2: scalar saves via `hermes config set`.
        var configKV: [String: String] = [:]
        if capabilities.hasGatewayBusyAckToggle {
            configKV["display.busy_ack_enabled"] =
                PlatformSetupHelpers.envBool(busyAckEnabled)
        }
        if capabilities.hasGatewayRestartNotification {
            configKV["gateway.platforms.\(platform).gateway_restart_notification"] =
                PlatformSetupHelpers.envBool(gatewayRestartNotification)
        }

        if configKV.isEmpty {
            message = "Allowlist saved — restart gateway to apply"
            return
        }

        let result = PlatformSetupHelpers.saveForm(
            context: context, envPairs: [:], configKV: configKV
        )
        message = result
    }
}
