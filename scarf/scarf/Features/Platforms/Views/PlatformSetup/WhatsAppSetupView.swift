import SwiftUI
import ScarfCore
import ScarfDesign

struct WhatsAppSetupView: View {
    @State private var viewModel: WhatsAppSetupViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    let context: ServerContext

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: WhatsAppSetupViewModel(context: context))
    }


    /// `"decline"` only from v0.21.4 — see
    /// `HermesCapabilities.hasWhatsAppUnauthorizedDMDecline`. A host below
    /// the floor coerces an on-disk `decline` back to `pair`
    /// (`_normalize_choice`, `gateway/config.py:144-147` @ `v2026.9.24`), so
    /// the picker must not OFFER a choice the host itself rejects. `PickerRow`
    /// has no built-in widening (unlike `WebToolsBackendRoster.finalize`), so
    /// a config that already reads `decline` (hand-edited, or a downgrade
    /// from a newer host) is widened in HERE — otherwise the `Picker` shows
    /// no matching selection at all for a value this list doesn't carry.
    private var unauthorizedDMOptions: [String] {
        let base = viewModel.unauthorizedOptions
        let declineOffered = capabilitiesStore?.capabilities.hasWhatsAppUnauthorizedDMDecline == true
        guard declineOffered || viewModel.unauthorizedDMBehavior == "decline" else { return base }
        return base + ["decline"]
    }

    /// `"decline"`'s row label: a plain choice once the host actually
    /// honors it, else a sentence saying so — a pre-0.21.4 host's own
    /// `_normalize_choice` silently coerces it back to `pair`
    /// (`gateway/config.py:144-147` @ `v2026.9.24`), so showing it as an
    /// ordinary working option would tell the user their selection does
    /// something it does not.
    private func unauthorizedDMOptionLabel(_ option: String) -> String {
        guard option == "decline",
              capabilitiesStore?.capabilities.hasWhatsAppUnauthorizedDMDecline != true
        else { return option }
        return "decline (not supported by this Hermes — behaves as pair)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            instructions

            SettingsSection(title: "Status", icon: "power") {
                ToggleRow(label: "WhatsApp Enabled", isOn: viewModel.enabled) { viewModel.enabled = $0 }
                PickerRow(label: "Mode", selection: viewModel.mode, options: viewModel.modeOptions) { viewModel.mode = $0 }
            }

            SettingsSection(title: "Access Control", icon: "person.badge.shield.checkmark") {
                ToggleRow(label: "Allow All Users", isOn: viewModel.allowAllUsers) { viewModel.allowAllUsers = $0 }
                if !viewModel.allowAllUsers {
                    EditableTextField(label: "Allowed Numbers", value: viewModel.allowedUsers) { viewModel.allowedUsers = $0 }
                }
            }

            SettingsSection(title: "Behavior", icon: "slider.horizontal.3") {
                PickerRow(
                    label: "Unauthorized DM",
                    selection: viewModel.unauthorizedDMBehavior,
                    options: unauthorizedDMOptions,
                    optionLabel: unauthorizedDMOptionLabel
                ) { viewModel.unauthorizedDMBehavior = $0 }
                // "decline" — send one polite refusal, then go silent toward
                // that sender — is v0.21.4+
                // (`HermesCapabilities.hasWhatsAppUnauthorizedDMDecline`).
                // The custom message is offered only while "decline" is the
                // active choice, same show/hide pattern as every other
                // conditional row in this form. The message itself is a
                // GLOBAL setting (`unauthorized_dm_decline_message`, no
                // per-platform override — see `WhatsAppSettings
                // .unauthorizedDMDeclineMessage`'s doc comment): every
                // platform's decline reply uses the same text, so the label
                // says so even though this is the only form that edits it.
                if viewModel.unauthorizedDMBehavior == "decline" {
                    EditableTextField(
                        label: "Decline Message (all platforms)",
                        value: viewModel.unauthorizedDMDeclineMessage
                    ) { viewModel.unauthorizedDMDeclineMessage = $0 }
                    .help("Applies to every platform's decline reply, not just WhatsApp's. Empty uses Hermes's own default reply.")
                }
                EditableTextField(label: "Reply Prefix", value: viewModel.replyPrefix) { viewModel.replyPrefix = $0 }
            }

            saveBar

            // v0.13 Messaging Gateway behavior — self-hides on pre-v0.13.
            GatewayBehaviorSection(
                platform: "whatsapp",
                capabilities: capabilitiesStore?.capabilities ?? .empty,
                context: context
            )

            Divider()
            pairingSection
        }
        .onAppear { viewModel.load() }
        .onDisappear { viewModel.stopPairing() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WhatsApp uses the Baileys library to emulate a WhatsApp Web session. Pair this Mac as a linked device by running the pairing wizard and scanning the QR code with your phone (Settings → Linked Devices → Link a Device).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("WhatsApp Setup Docs") { PlatformSetupHelpers.openURL("https://hermes-agent.nousresearch.com/docs/user-guide/messaging/whatsapp") }
                    .controlSize(.small)
            }
        }
    }

    private var saveBar: some View {
        HStack {
            OutcomeMessageBar(
                text: viewModel.message,
                kind: viewModel.messageKind,
                onDismiss: { viewModel.dismissMessage() }
            )
            Spacer()
            Button("Reload") { viewModel.load() }.controlSize(.small)
                    .disabled(viewModel.isBusy)
            Button("Save") { viewModel.save() }.buttonStyle(ScarfPrimaryButton()).controlSize(.small)
                // Disabled until the (now off-main, C10) load has landed:
                // `saveForm` treats a blank field as an unset, so a Save from
                // the pre-load blanks would comment live keys out of `.env`.
                .disabled(viewModel.isBusy)
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Pair Device", systemImage: "qrcode")
                    .font(.headline)
                Spacer()
                if viewModel.pairingInProgress {
                    Button("Stop") { viewModel.stopPairing() }
                        .controlSize(.small)
                } else {
                    Button("Start Pairing") { viewModel.startPairing() }
                        .buttonStyle(ScarfPrimaryButton())
                        .controlSize(.small)
                        // Round-5 decision 15: the embedded terminal spawns
                        // on THIS Mac, and `hermesBinary` is the remote path.
                        .disabled(viewModel.remotePairingNotice != nil)
                }
            }
            // On a remote context the terminal below can only mislead, so the
            // sentence naming the host REPLACES the how-to rather than
            // sitting beside it.
            if let notice = viewModel.remotePairingNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("A QR code will appear below. Scan it with WhatsApp on your phone. The session is saved to ~/.hermes/platforms/whatsapp/ so you won't need to scan again after restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EmbeddedSetupTerminal(controller: viewModel.terminalController)
                    .frame(minHeight: 260, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
