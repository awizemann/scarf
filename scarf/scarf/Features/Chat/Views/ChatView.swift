import SwiftUI

struct ChatView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(HermesFileWatcher.self) private var fileWatcher

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            terminalArea
        }
        .navigationTitle("Chat")
        .task { await viewModel.loadRecentSessions() }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.loadRecentSessions() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)

            if viewModel.hasActiveProcess {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                Text("No active session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.hasActiveProcess {
                voiceControls
            }

            if !viewModel.hermesBinaryExists {
                Label("Hermes binary not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Menu {
                Button("New Session") {
                    viewModel.startNewSession()
                }
                Button("Continue Last Session") {
                    viewModel.continueLastSession()
                }
                if !viewModel.recentSessions.isEmpty {
                    Divider()
                    Text("Resume Session")
                    ForEach(viewModel.recentSessions) { session in
                        Button {
                            viewModel.resumeSession(session.id)
                        } label: {
                            HStack {
                                Text(viewModel.previewFor(session))
                                    .lineLimit(1)
                                if let date = session.startedAt {
                                    Text("·")
                                        .foregroundStyle(.secondary)
                                    Text(date, style: .relative)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } label: {
                Label("Session", systemImage: "play.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var voiceControls: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.toggleVoice()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.voiceEnabled ? "mic.fill" : "mic.slash")
                        .foregroundStyle(viewModel.voiceEnabled ? .green : .secondary)
                    Text(viewModel.voiceEnabled ? "Voice On" : "Voice Off")
                        .font(.caption)
                        .foregroundStyle(viewModel.voiceEnabled ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Toggle voice mode (/voice)")

            if viewModel.voiceEnabled {
                Button {
                    viewModel.pushToTalk()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isRecording ? "waveform.circle.fill" : "waveform.circle")
                            .foregroundStyle(viewModel.isRecording ? .red : .accentColor)
                            .symbolEffect(.pulse, isActive: viewModel.isRecording)
                        Text(viewModel.isRecording ? "Recording..." : "Push to Talk")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Push to talk (Ctrl+B)")
                .keyboardShortcut("b", modifiers: .control)
            }
        }
    }

    @ViewBuilder
    private var terminalArea: some View {
        if let terminal = viewModel.terminalView {
            PersistentTerminalView(terminalView: terminal)
        } else if viewModel.hermesBinaryExists {
            ContentUnavailableView(
                "No Active Session",
                systemImage: "terminal",
                description: Text("Start a new session or resume an existing one from the Session menu above.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Hermes Not Found",
                systemImage: "terminal",
                description: Text("Expected at \(HermesPaths.hermesBinary)")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
