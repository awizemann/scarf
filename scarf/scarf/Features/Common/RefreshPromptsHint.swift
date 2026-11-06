import SwiftUI
import ScarfCore
import ScarfDesign

/// Runs `hermes sessions refresh-prompts --json` (v0.22.6+) off the main
/// actor and judges it with ``HermesSessionsRefreshPrompts/judge(stdout:stderr:exitCode:)``.
/// Shared by the post-save hint below and the Sessions context menu.
enum PromptRefreshRunner {
    static func run(context: ServerContext, sessionId: String? = nil) async -> (succeeded: Bool, message: String) {
        let result = await OffPool.run {
            context.runHermesSplit(HermesSessionsRefreshPrompts.argv(sessionId: sessionId), timeout: 30)
        }
        let verdict = HermesSessionsRefreshPrompts.judge(
            stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        return (verdict.succeeded, HermesSessionsRefreshPrompts.message(for: verdict, sessionId: sessionId))
    }
}

/// Non-intrusive hint shown after Scarf saves SOUL.md or a skill file:
/// continuing sessions keep the prompt they were built with until asked to
/// rebuild it. Renders nothing unless `isVisible` and the host has
/// `hasSessionsRefreshPrompts`, so older hosts are unchanged (charter C1).
struct RefreshPromptsHint: View {
    let context: ServerContext
    let isVisible: Bool
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var isRunning = false
    @State private var outcome: (succeeded: Bool, message: String)?

    var body: some View {
        if isVisible, capabilitiesStore?.capabilities.hasSessionsRefreshPrompts ?? false {
            HStack(alignment: .firstTextBaseline, spacing: ScarfSpace.s2) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .accessibilityHidden(true)
                Text(outcome?.message ?? "Running sessions keep their current system prompt until refreshed.")
                    .scarfStyle(.caption)
                    .foregroundStyle(outcome.map { $0.succeeded ? ScarfColor.foregroundMuted : ScarfColor.danger }
                                     ?? ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if outcome?.succeeded != true {
                    Button(isRunning ? "Refreshing…" : "Refresh running sessions") {
                        isRunning = true
                        Task {
                            outcome = await PromptRefreshRunner.run(context: context)
                            isRunning = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRunning)
                    .help("hermes sessions refresh-prompts: each continuing session rebuilds its system prompt on its next turn")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
