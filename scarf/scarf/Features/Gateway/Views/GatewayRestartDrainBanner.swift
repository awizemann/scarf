import SwiftUI
import ScarfCore
import ScarfDesign

/// Progress for a gateway restart Hermes is holding for the current turn
/// (S07-F3) — shared by the Gateway pane and Platforms. Renders nothing
/// while the watcher is idle.
struct GatewayRestartDrainBanner: View {
    let watcher: GatewayRestartDrainWatcher

    var body: some View {
        if let headline = watcher.headline {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if watcher.isWatching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                    }
                    Text(headline)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if watcher.isWatching {
                        Button("Stop Waiting") { watcher.stopWatching() }
                            .controlSize(.small)
                            .help(watcher.waitsForIdle
                                  ? "Stops Scarf watching. Hermes still restarts the gateway once it's idle."
                                  : "Stops Scarf watching. Hermes still restarts the gateway when the turn ends.")
                    } else {
                        Button("Dismiss") { watcher.reset() }
                            .controlSize(.small)
                    }
                }
                if !watcher.pendingWork.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Still running:")
                        ForEach(watcher.pendingWork, id: \.self) { line in
                            Text(verbatim: "• \(line)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if watcher.isWatching, watcher.waitsForIdle, let started = watcher.startedAt {
                    // v0.23.2+: no upper bound; the timeout only spaces out
                    // log warnings (`gateway/restart_when_idle.py`).
                    Text("Waiting since \(started, style: .time). Hermes keeps serving and restarts the gateway when nothing is running; it doesn't interrupt work in progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if watcher.isWatching, let started = watcher.startedAt {
                    // Hermes caps this wait with `agent.restart_after_turn_timeout`
                    // (30 minutes by default).
                    Text("Waiting since \(started, style: .time). Hermes stops waiting after agent.restart_after_turn_timeout (30 minutes by default).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ScarfSpace.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .accessibilityElement(children: .combine)
        }
    }

    private var symbol: String {
        switch watcher.status {
        case .restarted: "checkmark.circle.fill"
        case .failed, .gaveUp, .notRevived: "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch watcher.status {
        case .restarted: ScarfColor.success
        case .failed, .gaveUp, .notRevived: ScarfColor.warning
        default: .secondary
        }
    }
}
