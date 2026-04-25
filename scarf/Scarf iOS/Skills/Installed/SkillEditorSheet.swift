import SwiftUI
import ScarfCore

/// Sheet-presented TextEditor for the currently-selected skill file.
/// Save commits via `vm.saveEdit()` (which calls `transport.writeFile`);
/// Cancel discards. Validation lives entirely in the VM
/// (`isValidSkillPath` guard) so the sheet is purely UI.
struct SkillEditorSheet: View {
    @Bindable var vm: SkillsViewModel
    let fileName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $vm.editText)
                .font(.footnote.monospaced())
                .padding(8)
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
                            vm.saveEdit()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.large])
    }
}
