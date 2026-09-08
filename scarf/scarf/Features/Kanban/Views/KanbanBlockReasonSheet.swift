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

            ScarfTextField("Reason (optional)", text: $reason)
                .focused($fieldFocused)

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
                .accessibilityIdentifier("kanban.block.confirm")
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }
}
