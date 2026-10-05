import SwiftUI
import ScarfCore
import ScarfDesign

/// Yellow banner that nudges users to upgrade Hermes when the remote
/// is running pre-v0.12. Shown on the Dashboard tab; auto-dismissed
/// for the rest of the session when the user taps the X. Persistent
/// re-show on each app open keeps the prompt visible without nagging
/// inside a single session.
///
/// Hidden entirely on v0.12+ (the new features are reachable) and
/// while capability detection is still in flight.
struct HermesVersionBanner: View {
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var dismissedThisSession = false

    /// Capability gate — only render when:
    /// - the store finished its initial detection AND
    /// - the host returned an actual version string AND
    /// - that version is below v0.12 AND
    /// - the user hasn't dismissed this banner during this session.
    private var shouldShow: Bool {
        guard let store = capabilitiesStore else { return false }
        let caps = store.capabilities
        guard caps.detected else { return false }    // skip while loading / on detection failure
        guard !caps.hasCurator else { return false } // already on v0.12+
        return !dismissedThisSession
    }

    var body: some View {
        if shouldShow {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScarfColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes update available")
                        .font(.callout.weight(.semibold))
                    Text("This server runs \(versionLabel). Update to v0.12 to unlock the autonomous curator, multimodal image input, GMI Cloud / Azure / LM Studio / MiniMax / Tencent providers, and more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    dismissedThisSession = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss this version notice for the rest of the session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ScarfColor.warningTint.opacity(0.67))
            .overlay(
                Rectangle()
                    .fill(ScarfColor.warningHue.opacity(0.4))
                    .frame(height: 1),
                alignment: .bottom
            )
            .transition(.opacity)
        }
    }

    /// Pretty-print the detected version. Falls back to the raw line
    /// if parsing didn't extract semver — keeps the banner honest
    /// when Hermes ships an unexpected version string.
    private var versionLabel: String {
        let caps = capabilitiesStore?.capabilities
        if let semver = caps?.semver {
            return "Hermes v\(semver.description)"
        }
        return caps?.versionLine ?? "an older Hermes"
    }
}
