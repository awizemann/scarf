import SwiftUI
import ScarfCore
import ScarfDesign

/// Modal sheet that prompts for a "result summary" before firing
/// `kanban complete`. The result is handed to child tasks as upstream
/// context.
///
/// `resultRequired` is true when Hermes would refuse a blank completion
/// (0.21.4+, from any column but Review, for a task with no stored result —
/// `KanbanBoardViewModel.completionNeedsResult`). Then Complete stays
/// disabled until the field has text. Otherwise the result is optional.
struct KanbanCompleteResultSheet: View {
    @Environment(\.dismiss) private var dismiss

    let taskTitle: String
    var resultRequired: Bool = false
    let onSubmit: (String?) -> Void

    private var fieldPlaceholder: LocalizedStringKey {
        resultRequired ? "Result summary" : "Result summary (optional)"
    }

    private var footnote: LocalizedStringKey {
        resultRequired
            ? "Hermes needs a short note on what was done before it marks this task complete. If the task has child tasks, the result is handed to them as upstream context."
            : "If this task has child tasks, the result is handed to them as upstream context. Leave blank for a quiet completion."
    }

    private var trimmedResult: String {
        result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @State private var result: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Complete task")
                    .scarfStyle(.title3)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(taskTitle)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(2)
            }

            ScarfTextField(fieldPlaceholder, text: $result)
                .focused($fieldFocused)

            Text(footnote)
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundFaint)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ScarfSecondaryButton())
                Button("Complete") {
                    onSubmit(trimmedResult)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ScarfPrimaryButton())
                .disabled(resultRequired && trimmedResult.isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 460)
        .onAppear { fieldFocused = true }
    }
}
