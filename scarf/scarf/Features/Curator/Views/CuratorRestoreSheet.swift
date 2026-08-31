import SwiftUI
import ScarfCore
import ScarfDesign

/// Legacy v0.12 fallback for restoring an archived skill by typed
/// name. Hermes v0.12 didn't ship `curator list-archived`, so the only
/// way to restore was to remember the skill name and pass it through
/// `hermes curator restore <name>`.
///
/// **v0.13+ flow (preferred):** `CuratorArchivedSection` renders a
/// per-skill list with a one-click Restore button per row — no typing
/// required. This sheet stays reachable from the overflow menu only on
/// pre-v0.13 hosts (gated by `!hasCuratorArchive`). Don't delete this
/// file even after WS-4 ships; v0.12 hosts still depend on it.
struct CuratorRestoreSheet: View {
    let viewModel: CuratorViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var skillName: String = ""
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Restore Archived Skill")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)

            Text("Hermes archives skills the curator decides are stale or redundant. Restoring brings the original SKILL.md back into place — no data lost.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)

            VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                Text("Skill name")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                ScarfTextField("e.g. legacy-helper", text: $skillName)
                    .accessibilityLabel("Skill name")
            }

            Text("\(viewModel.status.archivedSkills) archived skill(s) available — list them with `hermes curator status`.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(ScarfGhostButton())
                Button("Restore") {
                    let trimmed = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isRestoring = true
                    Task {
                        await viewModel.restore(trimmed)
                        isRestoring = false
                        dismiss()
                    }
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(isRestoring || skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 420)
    }
}
