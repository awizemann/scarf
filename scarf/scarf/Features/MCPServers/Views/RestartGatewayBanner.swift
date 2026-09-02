import SwiftUI

struct RestartGatewayBanner: View {
    let onRestart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Gateway restart required")
                    .font(.caption.bold())
                Text("Changes won't take effect until Hermes reloads the config.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Title + explanation read as one announcement; the two
            // buttons stay outside it.
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Restart Now") { onRestart() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Dismiss"))
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }
}
