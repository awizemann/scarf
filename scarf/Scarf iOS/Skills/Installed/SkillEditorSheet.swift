import SwiftUI
import ScarfCore

/// Sheet-presented TextEditor for the currently-selected skill file.
/// Save commits via `vm.saveEdit()` (which calls `transport.writeFile`);
/// Cancel discards. Validation lives entirely in the VM
/// (`isValidSkillPath` guard) so the sheet is purely UI.
///
/// Save is outcome-driven. It used to `dismiss()` unconditionally right
/// after `await vm.saveEdit()`, so a refused write — a path outside the
/// skills dir, a missing proof token, a transport failure — closed the
/// sheet on the user's edits and looked exactly like a success. The VM
/// already models the outcome: `saveEdit` clears `isEditing` only when
/// `contentError` is nil, which is the Mac editor's behavior too. This
/// sheet now reads that same signal and stays open, showing the reason.
struct SkillEditorSheet: View {
    @Bindable var vm: SkillsViewModel
    let fileName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The only place a failed save is visible now that the
                // sheet survives one.
                if let error = vm.contentError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Not saved: \(error)"))
                }
                TextEditor(text: $vm.editText)
                    .font(.footnote.monospaced())
                    .padding(8)
            }
            .navigationTitle(fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        vm.cancelEditing()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            await vm.saveEdit()
                            // `saveEdit` leaves `isEditing` true on a refused
                            // or failed write. Dismissing there would discard
                            // the user's buffer and confirm a save that never
                            // happened.
                            if !vm.isEditing { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(vm.isSavingContent)
                }
            }
        }
        .presentationDetents([.large])
    }
}
