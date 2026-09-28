import SwiftUI
import ScarfDesign

/// Caption under a setting whose env var has a line in `.env` — says when
/// that line, not config.yaml, is what the gateway uses (B13).
struct EnvOverrideCaption: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.vertical, 6)
        }
    }
}
