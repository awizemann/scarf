import SwiftUI
import ScarfCore

struct MemoryView: View {
    @State private var viewModel: MemoryViewModel
    @State private var showResetConfirm: Bool = false
    @State private var resetError: String?
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: MemoryViewModel(context: context))
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.hasMultipleProfiles {
                    HStack(spacing: 8) {
                        Text("Profile")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { viewModel.activeProfile },
                            set: { viewModel.switchProfile($0) }
                        )) {
                            Text("Default").tag("")
                            ForEach(viewModel.profiles, id: \.self) { profile in
                                Text(profile).tag(profile)
                            }
                        }
                        .frame(maxWidth: 200)
                    }
                }
                if viewModel.hasExternalProvider {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("Memory is managed by \(viewModel.memoryProvider). File contents shown here may be stale.")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                memorySection("Agent Memory", content: viewModel.memoryContent, charCount: viewModel.memoryCharCount, target: .memory)
                memorySection("User Profile", content: viewModel.userContent, charCount: viewModel.userCharCount, target: .user)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Memory")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading memory…",
            isEmpty: viewModel.memoryContent.isEmpty && viewModel.userContent.isEmpty
        )
        .onAppear { viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            viewModel.load()
        }
        .sheet(isPresented: $viewModel.isEditing) {
            editorSheet
        }
        .toolbar {
            // v2.5: `hermes memory reset` (Hermes v2026.4.23+) wipes
            // both MEMORY.md and USER.md atomically — useful when a
            // session went off the rails. Destructive, confirmation-
            // gated, surfaced as a small toolbar button rather than
            // a prominent button to avoid accidental clicks.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showResetConfirm = true
                } label: {
                    Label("Reset memory…", systemImage: "arrow.counterclockwise")
                }
                .help("Reset MEMORY.md and USER.md to empty (Hermes v2026.4.23+)")
            }
        }
        .confirmationDialog(
            "Reset memory?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetMemoryRemotely()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wipes MEMORY.md and USER.md to empty via `hermes memory reset --yes`. The agent's accumulated knowledge for this server is gone immediately. Use this when a session went off the rails — there's no undo.")
        }
        .alert("Couldn't reset memory", isPresented: Binding(
            get: { resetError != nil },
            set: { if !$0 { resetError = nil } }
        )) {
            Button("OK") { resetError = nil }
        } message: {
            Text(resetError ?? "")
        }
    }

    /// Run `hermes memory reset --yes` over the active context's
    /// transport. Refreshes the on-screen content on success; surfaces
    /// stderr in an alert on failure.
    private func resetMemoryRemotely() {
        let result = viewModel.context.runHermes(["memory", "reset", "--yes"])
        if result.exitCode == 0 {
            viewModel.load()
        } else {
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            resetError = trimmed.isEmpty
                ? "hermes memory reset exited with status \(result.exitCode)."
                : trimmed
        }
    }

    private func memorySection(_ title: String, content: String, charCount: Int, target: MemoryViewModel.EditTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(charCount) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Edit") {
                    viewModel.startEditing(target)
                }
                .controlSize(.small)
            }
            if content.isEmpty {
                Text("Empty")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                MarkdownContentView(content: content)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var editorSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.editingFile == .memory ? "Edit Agent Memory" : "Edit User Profile")
                    .font(.headline)
                Spacer()
                Button("Cancel") { viewModel.cancelEditing() }
                Button("Save") { viewModel.save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            HSplitView {
                TextEditor(text: $viewModel.editText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                ScrollView {
                    MarkdownContentView(content: viewModel.editText)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
