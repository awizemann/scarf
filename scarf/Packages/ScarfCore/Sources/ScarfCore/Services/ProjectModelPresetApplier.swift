import Foundation

/// Applies a project's bound model preset to a freshly opened ACP session,
/// for the Mac chat and ScarfGo alike (S11-F3 — iOS never applied it, so a
/// project bound to a preset silently ran on the config.yaml default).
///
/// Two reads — the project's `.scarf/manifest.json` binding
/// (`ProjectModelPresetReader`) and the preset store
/// (`ModelPresetService`) — then `session/set_model`. The manifest read is
/// transport I/O (SFTP / SSH on a remote), so it runs off the caller's
/// actor. Non-fatal at every step: the outcome says what happened, and the
/// session keeps the config.yaml default unless it is `.applied`.
///
/// No capability gate: `session/set_model` is in the ACP adapter at every
/// tag Scarf supports (`acp_adapter/server.py:482` @ v2026.3.30 = 0.6.0;
/// `:1015` @ v2026.9.24). P49.
public enum ProjectModelPresetApplier {

    public enum Outcome: Sendable, Equatable {
        /// The project has no preset binding — the global default applies.
        case noBinding
        /// The manifest names a preset id that isn't in the store (deleted).
        case presetMissing(id: String)
        /// The preset store couldn't be read.
        case storeUnreadable(message: String)
        /// Hermes accepted the preset for this session.
        case applied(ModelPreset)
        /// Hermes refused `session/set_model`; the session stays on the
        /// config.yaml default.
        case rejected(ModelPreset, message: String)

        /// The preset the session actually runs on, if any.
        public var appliedPreset: ModelPreset? {
            if case .applied(let preset) = self { return preset }
            return nil
        }
    }

    /// Resolve the project's binding and apply it to `sessionId`.
    public static func apply(
        client: ACPClient,
        sessionId: String,
        projectPath: String,
        context: ServerContext,
        readBinding: @escaping @Sendable (ServerContext, String) -> String? = { ctx, path in
            ProjectModelPresetReader(context: ctx).presetID(forProjectPath: path)
        }
    ) async -> Outcome {
        // `OffPool.run`, not `Task.detached` (P60, same as
        // `CuratorService.status`): on a remote host the manifest read is a
        // blocking SFTP / SSH round trip, and `Task.detached` would park a
        // cooperative-pool thread through it (charter C10).
        let idString = await OffPool.run { readBinding(context, projectPath) }
        guard let idString, let presetID = UUID(uuidString: idString) else {
            return .noBinding
        }
        let preset: ModelPreset?
        do {
            preset = try await ModelPresetService.shared(for: context).get(id: presetID)
        } catch {
            return .storeUnreadable(message: error.localizedDescription)
        }
        guard let preset else { return .presetMissing(id: idString) }
        do {
            // Pass providerID so the RPC uses Hermes's `<provider>:<model>`
            // wire form. Without it, less-obvious model ids (e.g.
            // `inclusionai/ring-2.6-1t`) fall into
            // `detect_provider_for_model`, which guesses wrong (issue #97).
            // An empty providerID (presets older than the field) falls back
            // to the bare model id.
            try await client.setSessionModel(
                sessionId: sessionId,
                modelID: preset.modelID,
                providerID: preset.providerID.isEmpty ? nil : preset.providerID
            )
            return .applied(preset)
        } catch {
            return .rejected(preset, message: error.localizedDescription)
        }
    }
}
