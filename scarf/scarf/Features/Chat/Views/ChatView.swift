import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            terminalArea
        }
        .navigationTitle("Chat")
    }

    private var toolbar: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Hermes Terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.hermesBinaryExists {
                Label("Hermes binary not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("New Session") {
                viewModel.sessionId = UUID()
            }
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var terminalArea: some View {
        if viewModel.hermesBinaryExists {
            TerminalRepresentable(
                command: HermesPaths.hermesBinary,
                arguments: ["chat"],
                environment: [:]
            )
            .id(viewModel.sessionId)
        } else {
            ContentUnavailableView(
                "Hermes Not Found",
                systemImage: "terminal",
                description: Text("Expected at \(HermesPaths.hermesBinary)")
            )
        }
    }
}
