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
    /// P47 / round-5 decision 3: the neutral note a reset with nothing to
    /// reset carries, in place of the "were cleared" sentence. Nil on a reset
    /// that actually erased files. The Mac twin is `MemoryView.resetNote`.
    @State private var resetNote: String?

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    var body: some View {
        let ctx = config.toServerContext(id: Self.sharedContextID)
        List {
            Section {
                memoryRow(.memory, context: ctx)
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                memoryRow(.user, context: ctx)
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                memoryRow(.soul, context: ctx)
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
            } footer: {
                Text("MEMORY.md and USER.md live under `~/.hermes/memories/`. SOUL.md lives at `~/.hermes/SOUL.md`.")
                    .font(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
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
            Button("OK") { resetNote = nil }
        } message: {
            Text(resetNote ?? String(localized: "MEMORY.md and USER.md were cleared on the host."))
        }
    }

    /// Run `hermes memory reset --yes` over the iOS context's transport
    /// (Citadel SSH exec). Mirrors the PATH-prefix trick
    /// IOSSettingsViewModel.saveValue uses so non-interactive shells
    /// find hermes even when it's in `~/.local/bin` or `/opt/homebrew/bin`.
    private func resetMemory(context: ServerContext) async {
        let hermes = context.paths.hermesBinary
        // `COLUMNS` first, for the same reason the Mac's transports carry it
        // (P40b) and `CitadelServerTransport.asyncRunProcess` now does
        // (P54): this spawn is JUDGED BY OUTPUT — `HermesMemoryResetVerdict`
        // matches whole lines — and `rich` wraps at 80 columns when stdout
        // is not a TTY.
        //
        // It is set HERE as well as in the transport because this script is
        // handed to `/bin/sh -c` as one string: the transport's own prefix
        // sets `COLUMNS` for the `sh`, and `sh` does export it to `hermes`,
        // but this call site is the only thing that keeps working if the
        // context ever hands back a transport that composes its command
        // differently. Belt and braces on a line that is free.
        //
        // The assignment leads, as it must: `sh` reads a command line's
        // leading `VAR=value` pairs left to right, and the first token that
        // is not an assignment becomes the command.
        let script = "COLUMNS=\(LocalTransport.wideColumns) "
            + "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.hermes/bin:$PATH\" "
            + "\(hermes) \(HermesMemoryResetVerdict.argv.joined(separator: " "))"
        let ctx = context
        do {
            // Round-6 decision 11: the `async` seam, so the wait is a
            // SUSPENSION rather than a cooperative-pool thread blocked on a
            // semaphore while the exec it waits for runs on that same pool.
            let result = try await ctx.makeTransport().asyncRunProcess(
                executable: "/bin/sh",
                args: ["-c", script],
                stdin: nil,
                timeout: 15
            )
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            // P47 / round-5 decision 3: judged by OUTPUT, exactly as the Mac
            // twin. `_cmd_memory_reset`'s nothing-to-do arm prints
            // `Nothing to reset — no memory files found in …` and RETURNS at
            // exit 0 (`hermes_cli/main_agent_cmds.py:32-33` @ `v2026.9.7`),
            // so this alert claimed the two files "were cleared" over a run
            // that found none. A success either way — the memory IS empty —
            // with the note saying which of the two happened.
            let outcome = HermesMemoryResetVerdict.judge(
                output: combined, exitCode: result.exitCode
            )
            if outcome.succeeded {
                resetNote = outcome.warning
                resetSucceeded = true
            } else {
                // A non-zero exit names the status; an exit-0 run that
                // printed neither marker is `.unconfirmed`, and "status 0"
                // would be the old bug in a new voice — say that Hermes
                // printed nothing this side recognises instead. Shared with
                // the Mac twin through
                // ``HermesMemoryResetVerdict/failureSummary`` — `detail ??`
                // collapsed the unconfirmed arm into the quoted one whenever
                // the run printed ANY line.
                resetError = HermesMemoryResetVerdict.failureSummary(
                    outcome: outcome, exitCode: result.exitCode)
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
