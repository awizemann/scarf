import SwiftUI
import ScarfCore
import ScarfDesign

/// Modal sheet that prompts for an optional "reason" string before
/// firing `kanban block`. Used by the drag-drop layer when a card
/// lands on the Blocked column.
struct KanbanBlockReasonSheet: View {
    @Environment(\.dismiss) private var dismiss

    let taskTitle: String
    let onSubmit: (String?) -> Void

    @State private var reason: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Block task")
                    .scarfStyle(.title3)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(taskTitle)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(2)
            }

            // Required, and the sheet says so: `KanbanService.plan` rejects an
            // empty reason for Ready→Blocked and Running→Blocked ("A reason is
            // required to mark a task blocked"), so a sheet that called it
            // optional and let Block through with nothing typed sent every
            // such move into the error banner instead of the Blocked column.
            ScarfTextField("Reason (required)", text: $reason)
                .focused($fieldFocused)
                .accessibilityIdentifier("kanban.block.reason")

            Text("Reasons appear as a comment on the task and feed into the worker's context if it's later unblocked.")
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundFaint)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ScarfSecondaryButton())
                Button("Block") {
                    onSubmit(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ScarfPrimaryButton())
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("kanban.block.confirm")
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }
}
