import SwiftUI
import ScarfCore
import ScarfDesign

/// Memory — visual layer follows `design/static-site/ui-kit/Memory.jsx`:
/// a left list of memory files + a right editor pane with header,
/// monospaced body, and stats footer. Scarf's data model has 2 files
/// (MEMORY.md and USER.md), not the mockup's N AGENTS.md scopes — we
/// surface those two as the list entries and keep the layout otherwise.
struct MemoryView: View {
    @State private var viewModel: MemoryViewModel
    @State private var showResetConfirm: Bool = false
    @State private var resetError: String?
    @State private var selectedFile: MemoryViewModel.EditTarget = .memory
    @State private var draftText: String = ""
    @State private var isDirty: Bool = false
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: MemoryViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            if viewModel.hasExternalProvider {
                externalProviderBanner
            }
            HStack(spacing: 0) {
                fileListPane
                Divider()
                    .background(ScarfColor.border)
                editorPane
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Memory")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading memory…",
            isEmpty: viewModel.memoryContent.isEmpty && viewModel.userContent.isEmpty
        )
        .onAppear {
            viewModel.load()
            syncDraftFromContent()
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            viewModel.load()
            syncDraftFromContent()
        }
        .onChange(of: selectedFile) {
            syncDraftFromContent()
        }
        .onChange(of: viewModel.memoryContent) { syncDraftFromContent() }
        .onChange(of: viewModel.userContent) { syncDraftFromContent() }
        .confirmationDialog(
            "Reset memory?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { resetMemoryRemotely() }
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

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Files the agent reads on every turn. Agent and user notes layered, narrower wins.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()

            if viewModel.hasMultipleProfiles {
                Picker("Profile", selection: Binding(
                    get: { viewModel.activeProfile },
                    set: { viewModel.switchProfile($0) }
                )) {
                    Text("Default").tag("")
                    ForEach(viewModel.profiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }

            HStack(spacing: ScarfSpace.s2) {
                Button {
                    showResetConfirm = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(ScarfGhostButton())
                .help("Reset MEMORY.md and USER.md to empty (Hermes v2026.4.23+)")

                Button {
                    discardEdits()
                } label: {
                    Label("Discard", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ScarfSecondaryButton())
                .disabled(!isDirty)

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(!isDirty)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var externalProviderBanner: some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "info.circle")
                .foregroundStyle(ScarfColor.warning)
            Text("Memory is managed by \(viewModel.memoryProvider). File contents shown here may be stale.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s2)
        .background(ScarfColor.warning.opacity(0.10))
    }

    // MARK: - File list pane

    private var fileListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Memory files")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal, ScarfSpace.s3)
                .padding(.top, ScarfSpace.s3)
                .padding(.bottom, ScarfSpace.s1)

            VStack(spacing: 2) {
                fileRow(.memory)
                fileRow(.user)
            }
            .padding(.horizontal, ScarfSpace.s2)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Files load top to bottom. Agent memory is checked first.")
                    .scarfStyle(.caption)
                    .lineLimit(2)
            }
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(ScarfSpace.s3)
            .overlay(
                Rectangle().fill(ScarfColor.border).frame(height: 1),
                alignment: .top
            )
        }
        .frame(width: 280)
        .background(ScarfColor.backgroundSecondary)
    }

    private func fileRow(_ target: MemoryViewModel.EditTarget) -> some View {
        let isActive = selectedFile == target
        let meta = fileMeta(target)
        return Button {
            selectedFile = target
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                    Text(meta.scope)
                        .scarfStyle(.bodyEmph)
                }
                .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)

                Text(meta.path)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(meta.size)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                    .fill(isActive ? ScarfColor.accentTint : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editor pane

    private var editorPane: some View {
        VStack(spacing: 0) {
            editorHeader
            TextEditor(text: $draftText)
                .font(ScarfFont.mono)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, ScarfSpace.s5)
                .padding(.vertical, ScarfSpace.s4)
                .background(ScarfColor.backgroundPrimary)
                .onChange(of: draftText) {
                    let live = currentContent
                    isDirty = (draftText != live)
                }
            editorFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorHeader: some View {
        HStack(spacing: ScarfSpace.s3) {
            Image(systemName: "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(ScarfColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(fileMeta(selectedFile).filename)
                    .scarfStyle(.bodyEmph)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(fileMeta(selectedFile).path)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            Spacer()
            ScarfBadge(isDirty ? "unsaved" : "saved", kind: isDirty ? .warning : .success)
        }
        .padding(.horizontal, ScarfSpace.s5)
        .padding(.vertical, ScarfSpace.s3)
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var editorFooter: some View {
        HStack(spacing: ScarfSpace.s3) {
            Text("markdown")
            Text("·")
            Text("\(draftText.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
            Text("·")
            Text("\(draftText.count) chars")
            Spacer()
        }
        .font(ScarfFont.monoSmall)
        .foregroundStyle(ScarfColor.foregroundFaint)
        .padding(.horizontal, ScarfSpace.s5)
        .padding(.vertical, ScarfSpace.s2)
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - State sync

    private var currentContent: String {
        switch selectedFile {
        case .memory: return viewModel.memoryContent
        case .user:   return viewModel.userContent
        }
    }

    private func syncDraftFromContent() {
        draftText = currentContent
        isDirty = false
    }

    private func discardEdits() {
        syncDraftFromContent()
    }

    private func save() {
        viewModel.editingFile = selectedFile
        viewModel.editText = draftText
        viewModel.save()
        // viewModel.save() flips isEditing off and commits content async.
        // Mark clean now; the onChange of memoryContent/userContent will
        // re-sync once the write lands.
        isDirty = false
    }

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

    // MARK: - File metadata

    private struct FileMeta {
        let filename: String
        let scope: String
        let path: String
        let size: String
    }

    private func fileMeta(_ target: MemoryViewModel.EditTarget) -> FileMeta {
        switch target {
        case .memory:
            return FileMeta(
                filename: "MEMORY.md",
                scope: "Agent memory",
                path: "~/.hermes/memories/MEMORY.md",
                size: byteSize(viewModel.memoryContent)
            )
        case .user:
            return FileMeta(
                filename: "USER.md",
                scope: "User profile",
                path: "~/.hermes/memories/USER.md",
                size: byteSize(viewModel.userContent)
            )
        }
    }

    private func byteSize(_ s: String) -> String {
        let bytes = s.utf8.count
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        return String(format: "%.1f KB", kb)
    }
}
