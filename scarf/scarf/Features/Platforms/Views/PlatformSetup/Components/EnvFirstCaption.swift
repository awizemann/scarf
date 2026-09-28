import SwiftUI
import ScarfDesign

/// B05: says when a `.env` variable, not config.yaml, decides a setting on
/// this form (or would on Hermes 0.21.3+) — see `HermesEnvFirstSettings`.
/// Renders nothing when `.env` has no such line.
struct EnvFirstCaption: View {
    let state: PlatformSetupHelpers.EnvFirstState

    var body: some View {
        if let text = PlatformSetupHelpers.envFirstCaption(state) {
            Label {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 6)
        }
    }
}
