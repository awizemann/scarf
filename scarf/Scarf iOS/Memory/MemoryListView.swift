import SwiftUI
import ScarfCore
import ScarfDesign

/// Entry screen for the Memory feature. Three rows: MEMORY.md,
/// USER.md, and SOUL.md (persona). SOUL lives in the Personalities
/// feature on macOS; we fold it in here on iOS so the whole
/// "agent prompt inputs" surface is one tap away. Each row taps into
/// `MemoryEditorView`. Pure SwiftUI — the actual load/save happens in
/// `IOSMemoryViewModel` which lives in ScarfCore.
struct MemoryListView: View {
    let config: IOSServerConfig
    @State private var showResetConfirm = false
    @State private var resetError: String?
    @State private var resetSucceeded = false

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    var body: some View {
        let ctx = config.toServerContext(id: Self.sharedContextID)
        List {
            Section {
                memoryRow(.memory, context: ctx)
                    .scarfGoCompactListRow()
                memoryRow(.user, context: ctx)
                    .scarfGoCompactListRow()
                memoryRow(.soul, context: ctx)
                    .scarfGoCompactListRow()
            } footer: {
                Text("MEMORY.md and USER.md live under `~/.hermes/memories/`. SOUL.md lives at `~/.hermes/SOUL.md`.")
                    .font(.caption)
            }
        }
        .scarfGoListDensity()
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // v2.5: `hermes memory reset` (Hermes v2026.4.23+) wipes
            // both MEMORY.md and USER.md atomically. Surfaced as a
            // toolbar button (smaller fat-finger target than a list
            // row) gated behind a destructive confirmation dialog.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showResetConfirm = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset memory")
            }
        }
        .confirmationDialog(
            "Reset memory?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task { await resetMemory(context: ctx) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes MEMORY.md and USER.md to empty via `hermes memory reset --yes`. The agent's accumulated knowledge for this server is gone immediately. Use this only when a session went off the rails.")
        }
        .alert("Couldn't reset memory", isPresented: Binding(
            get: { resetError != nil },
            set: { if !$0 { resetError = nil } }
        )) {
            Button("OK") { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
        .alert("Memory reset", isPresented: $resetSucceeded) {
            Button("OK") {}
        } message: {
            Text("MEMORY.md and USER.md were cleared on the host.")
        }
    }

    /// Run `hermes memory reset --yes` over the iOS context's transport
    /// (Citadel SSH exec). Mirrors the PATH-prefix trick
    /// IOSSettingsViewModel.saveValue uses so non-interactive shells
    /// find hermes even when it's in `~/.local/bin` or `/opt/homebrew/bin`.
    private func resetMemory(context: ServerContext) async {
        let hermes = context.paths.hermesBinary
        let script = "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" \(hermes) memory reset --yes"
        let ctx = context
        do {
            let result = try await Task.detached {
                try ctx.makeTransport().runProcess(
                    executable: "/bin/sh",
                    args: ["-c", script],
                    stdin: nil,
                    timeout: 15
                )
            }.value
            if result.exitCode == 0 {
                resetSucceeded = true
            } else {
                let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
                resetError = combined.isEmpty
                    ? "hermes memory reset exited with status \(result.exitCode)."
                    : combined
            }
        } catch {
            resetError = "Couldn't reach Hermes: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func memoryRow(_ kind: IOSMemoryViewModel.Kind, context: ServerContext) -> some View {
        NavigationLink {
            MemoryEditorView(kind: kind, context: context)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.iconName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
