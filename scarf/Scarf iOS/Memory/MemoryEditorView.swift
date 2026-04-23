import SwiftUI
import ScarfCore

/// Editor for a single memory file (MEMORY.md or USER.md). Owns an
/// `IOSMemoryViewModel` instance, renders its `text` in a TextEditor,
/// and exposes Save + Revert toolbar buttons.
struct MemoryEditorView: View {
    @State private var vm: IOSMemoryViewModel
    @State private var showSavedConfirmation = false

    init(kind: IOSMemoryViewModel.Kind, context: ServerContext) {
        _vm = State(initialValue: IOSMemoryViewModel(kind: kind, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isLoading {
                Spacer()
                ProgressView("Loading \(vm.kind.displayName)…")
                Spacer()
            } else {
                TextEditor(text: $vm.text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 8)
                if let err = vm.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                }
            }
        }
        .navigationTitle(vm.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task {
                        let ok = await vm.save()
                        if ok {
                            showSavedConfirmation = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                showSavedConfirmation = false
                            }
                        }
                    }
                }
                .disabled(!vm.hasUnsavedChanges || vm.isSaving)
            }
            ToolbarItem(placement: .topBarLeading) {
                if vm.hasUnsavedChanges {
                    Button("Revert") { vm.revert() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedConfirmation {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSavedConfirmation)
        .task { await vm.load() }
    }
}
