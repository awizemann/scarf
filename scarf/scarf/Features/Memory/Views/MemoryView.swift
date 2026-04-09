import SwiftUI

struct MemoryView: View {
    @State private var viewModel = MemoryViewModel()
    @Environment(HermesFileWatcher.self) private var fileWatcher

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
        .onAppear { viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            viewModel.load()
        }
        .sheet(isPresented: $viewModel.isEditing) {
            editorSheet
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
                Text(markdownAttributed(content))
                    .textSelection(.enabled)
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
            TextEditor(text: $viewModel.editText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func markdownAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
