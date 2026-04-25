import SwiftUI
import ScarfCore
import ScarfDesign

/// Editor for a single memory file (MEMORY.md / USER.md / SOUL.md).
/// Owns an `IOSMemoryViewModel` instance, renders its `text` in a
/// TextEditor, and exposes Save + Revert toolbar buttons.
///
/// Keyboard layout (pass-1 M7 #9 + #10):
/// - TextEditor uses `.scrollDismissesKeyboard(.interactively)` so
///   the keyboard tracks the user's drag, keeping the cursor visible
///   when editing near the bottom.
/// - The error banner + Saved pill live in `.safeAreaInset(edge: .bottom)`
///   so they're drawn ABOVE the keyboard, not behind it. The Saved
///   pill now holds for 2.5s (up from 1.5s) and any in-flight hide
///   task is cancelled when a new save lands so rapid saves stack
///   predictably.
struct MemoryEditorView: View {
    @State private var vm: IOSMemoryViewModel
    @State private var showSavedConfirmation = false
    @State private var savedHideTask: Task<Void, Never>?

    init(kind: IOSMemoryViewModel.Kind, context: ServerContext) {
        _vm = State(initialValue: IOSMemoryViewModel(kind: kind, context: context))
    }

    var body: some View {
        Group {
            if vm.isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading \(vm.kind.displayName)…")
                    Spacer()
                }
            } else {
                TextEditor(text: $vm.text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollDismissesKeyboard(.interactively)
                    .padding(.horizontal, 8)
            }
        }
        .navigationTitle(vm.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await performSave() }
                }
                .disabled(!vm.hasUnsavedChanges || vm.isSaving)
            }
            ToolbarItem(placement: .topBarLeading) {
                if vm.hasUnsavedChanges {
                    Button("Revert") { vm.revert() }
                }
            }
        }
        // Pin feedback + error strips to the bottom safe area so they
        // draw above the keyboard. Previously they floated inside the
        // VStack and the keyboard covered both the save pill and the
        // cursor the user was typing into.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let err = vm.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
                }
                if showSavedConfirmation {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSavedConfirmation)
        .animation(.easeInOut(duration: 0.2), value: vm.lastError)
        .task { await vm.load() }
        .onDisappear { savedHideTask?.cancel() }
    }

    private func performSave() async {
        let ok = await vm.save()
        guard ok else { return }
        // Cancel any in-flight hide task so rapid saves don't drop
        // the pill mid-fade (the previous implementation stacked
        // overlapping sleep tasks).
        savedHideTask?.cancel()
        showSavedConfirmation = true
        savedHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                showSavedConfirmation = false
            }
        }
    }
}
