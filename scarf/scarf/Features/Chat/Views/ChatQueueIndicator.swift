import SwiftUI
import ScarfCore
import ScarfDesign

/// Header chip that surfaces prompts the user has queued via
/// `/queue …` (Hermes v0.13). Tap → popover listing the queued
/// prompt previews + their relative timestamps.
///
/// The chip is OPTIMISTIC — it's a Scarf-side mirror of what the user
/// typed. Hermes owns the authoritative queue server-side. The popover
/// header makes that explicit so the user understands per-entry
/// removal isn't supported (Hermes has no remove-by-id verb), and the
/// v2.8.0 plan removed the "Clear all" button rather than ship one
/// that would lie about its effect on server-side state. See WS-2 plan
/// Q2 for the wire-shape question that drove that decision.
struct ChatQueueIndicator: View {
    let queuedPrompts: [HermesQueuedPrompt]
    @State private var isPopoverShown = false

    var body: some View {
        if queuedPrompts.isEmpty {
            EmptyView()
        } else {
            chipButton
                .popover(isPresented: $isPopoverShown, arrowEdge: .bottom) {
                    queuePopover
                }
        }
    }

    private var chipButton: some View {
        Button {
            isPopoverShown = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                Text("\(queuedPrompts.count) queued")
            }
            .scarfStyle(.caption)
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(ScarfColor.warningTint.opacity(0.89)))
            .foregroundStyle(ScarfColor.warning)
        }
        .buttonStyle(.plain)
        .help("Prompts waiting to run after the current turn finishes")
    }

    @ViewBuilder
    private var queuePopover: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text("Queued prompts")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text("Local view — Hermes manages the actual queue server-side. The next prompt runs automatically when the current turn finishes.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
            ScarfDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    ForEach(queuedPrompts.indices, id: \.self) { index in
                        queueRow(queuedPrompts[index], position: index + 1)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
        }
        .padding(ScarfSpace.s4)
        .frame(width: 360)
    }

    @ViewBuilder
    private func queueRow(_ prompt: HermesQueuedPrompt, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Text("#\(position)")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Text(prompt.queuedAt, style: .relative)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .monospacedDigit()
            }
            Text(prompt.text)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
