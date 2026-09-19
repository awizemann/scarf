import SwiftUI
import ScarfCore
import ScarfDesign

struct VoiceLiveView: View {
    @State private var viewModel: VoiceLiveViewModel
    init(context: ServerContext) {
        _viewModel = State(initialValue: VoiceLiveViewModel(context: context))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            header
            MicLevelMeter(viewModel: viewModel, tint: statusColor)
            transcript
            controls
        }
        .padding(ScarfSpace.s5)
        .frame(minWidth: 460, minHeight: 340)
        .background(ScarfColor.backgroundPrimary)
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var header: some View {
        HStack(spacing: ScarfSpace.s3) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("GPT-Live")
                    .font(.headline)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }

            Spacer()
        }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                if !viewModel.hasTranscriptContent {
                    Text("Speak naturally once the session is listening.")
                        .font(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(Array(viewModel.userTranscriptBlocks.enumerated()), id: \.offset) { block in
                    transcriptBlock(title: "You", text: block.element, color: ScarfColor.foregroundPrimary)
                }
                if !viewModel.userTranscriptLive.isEmpty {
                    transcriptBlock(title: "You", text: viewModel.userTranscriptLive, color: ScarfColor.foregroundPrimary)
                }

                ForEach(Array(viewModel.assistantTranscriptBlocks.enumerated()), id: \.offset) { block in
                    transcriptBlock(title: "Hermes", text: block.element, color: ScarfColor.foregroundMuted)
                }
                if !viewModel.assistantTranscriptLive.isEmpty {
                    transcriptBlock(title: "Hermes", text: viewModel.assistantTranscriptLive, color: ScarfColor.foregroundMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ScarfSpace.s3)
        }
        .frame(minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
    }

    private func transcriptBlock(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text(text)
                .font(.body)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private var controls: some View {
        HStack {
            if case .failed = viewModel.phase {
                Button {
                    Task { await viewModel.start() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
            }

            Spacer()

            Button(role: isRunning ? .destructive : nil) {
                if isRunning {
                    viewModel.stop()
                } else {
                    Task { await viewModel.start() }
                }
            } label: {
                Label(isRunning ? "Stop" : "Start", systemImage: isRunning ? "stop.fill" : "mic.fill")
            }
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var isRunning: Bool {
        switch viewModel.phase {
        case .connecting, .listening, .speaking:
            return true
        case .idle, .ended, .failed:
            return false
        }
    }

    private var statusLabel: String {
        switch viewModel.phase {
        case .idle:
            return "Ready"
        case .connecting:
            return "Connecting"
        case .listening:
            return "Listening"
        case .speaking:
            return "Speaking"
        case .ended:
            return "Ended"
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .listening:
            return ScarfColor.success
        case .speaking:
            return ScarfColor.accent
        case .failed:
            return ScarfColor.danger
        default:
            return ScarfColor.foregroundMuted
        }
    }
}

/// The mic-level readout, isolated into its own view type so the
/// ~10 Hz level ticks re-evaluate only this subtree (a few view
/// values) instead of the whole session body — the transcript, whose
/// Texts grow over the session, sits in the parent's observation
/// scope and would otherwise re-diff on every tick.
private struct MicLevelMeter: View {
    let viewModel: VoiceLiveViewModel
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack {
                Text("Microphone")
                    .font(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer()
                Text(levelLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ScarfColor.backgroundSecondary)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(8, proxy.size.width * min(max(viewModel.micLevel * 3, 0), 1)))
                }
            }
            .frame(height: 8)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(levelLabel)
        }
    }

    private var levelLabel: String {
        "\(Int(min(max(viewModel.micLevel * 100, 0), 100)))%"
    }
}
