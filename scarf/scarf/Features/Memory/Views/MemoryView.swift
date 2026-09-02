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
    /// The on-disk text this draft was branched from. `isDirty` is measured
    /// against THIS, never against `viewModel.memoryContent` — once the
    /// watcher refreshes the live content under a dirty draft the two differ,
    /// and comparing to the live copy would call an edited buffer clean.
    @State private var baseline: String = ""
    /// Drafts survive switching between MEMORY.md and USER.md.
    @State private var stashedDrafts: [MemoryViewModel.EditTarget: (draft: String, baseline: String)] = [:]
    @State private var hasConflict: Bool = false
    @State private var saveError: String?

    private var isDirty: Bool { draftText != baseline }

    /// Any unsaved edit, including one stashed on the file that is not on
    /// screen — the profile picker has to respect those too.
    private var anyDirty: Bool {
        isDirty || stashedDrafts.contains { $0.value.draft != $0.value.baseline }
    }
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
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            // Refreshing the live content is always safe; adopting it into the
            // editor is not. `adoptExternalContent` makes that call.
            viewModel.load()
        }
        .onChange(of: selectedFile) { previous, _ in
            stashedDrafts[previous] = (draftText, baseline)
            restoreDraft(for: selectedFile)
        }
        .onChange(of: viewModel.activeProfile) {
            // Drafts are per-file-per-profile; the picker is disabled while any
            // are dirty, so nothing unsaved can be dropped here.
            stashedDrafts.removeAll()
            syncDraftFromContent()
        }
        .onChange(of: viewModel.memoryContent) { adoptExternalContent(for: .memory) }
        .onChange(of: viewModel.userContent) { adoptExternalContent(for: .user) }
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
                // Switching profile retargets the editor at a different file
                // on disk; the draft would then save into the wrong profile.
                .disabled(anyDirty)
                .help(anyDirty
                      ? "Save or discard your edits before switching profile."
                      : "Switch memory profile")
            }

            HStack(spacing: ScarfSpace.s2) {
                Button {
                    showResetConfirm = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(ScarfGhostButton())
                .help("Reset MEMORY.md and USER.md to empty (Hermes v2026.4.23+)")

                if viewModel.isSaving {
                    ProgressView().controlSize(.small)
                }

                if hasConflict {
                    Button {
                        reloadFromDisk()
                    } label: {
                        Label("Reload from Disk", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ScarfSecondaryButton())
                    .disabled(viewModel.isSaving)
                    .accessibilityLabel("Discard your edits and reload this file from disk")

                    Button {
                        save(force: true)
                    } label: {
                        Label("Overwrite", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(ScarfDestructiveButton())
                    .disabled(viewModel.isSaving)
                    .accessibilityLabel("Overwrite the changed file on disk with your edits")
                } else {
                    Button {
                        discardEdits()
                    } label: {
                        Label("Discard", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(ScarfSecondaryButton())
                    .disabled(!isDirty || viewModel.isSaving)

                    Button {
                        save()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(ScarfPrimaryButton())
                    .disabled(!isDirty || viewModel.isSaving)
                }
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
            if let saveError {
                Text(saveError)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ScarfSpace.s5)
                    .padding(.vertical, ScarfSpace.s2)
                    .background(ScarfColor.backgroundSecondary)
                    .accessibilityLabel(saveError)
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

    private func content(for target: MemoryViewModel.EditTarget) -> String {
        switch target {
        case .memory: return viewModel.memoryContent
        case .user:   return viewModel.userContent
        }
    }

    private func syncDraftFromContent() {
        baseline = currentContent
        draftText = currentContent
        hasConflict = false
        saveError = nil
    }

    private func restoreDraft(for target: MemoryViewModel.EditTarget) {
        hasConflict = false
        saveError = nil
        if let stashed = stashedDrafts[target] {
            draftText = stashed.draft
            baseline = stashed.baseline
        } else {
            baseline = currentContent
            draftText = currentContent
        }
    }

    /// A file changed underneath us — from the watcher, a profile switch, or
    /// the first load. Adopting it wholesale is what silently destroyed dirty
    /// drafts on every ~1.5s watcher tick while an agent was writing memory.
    ///
    /// Clean buffer → adopt, which keeps the ordinary refresh path intact.
    /// Dirty buffer → never touch the draft; raise a conflict only if the disk
    /// copy actually moved off the baseline (a tick with identical content is
    /// not a conflict).
    private func adoptExternalContent(for target: MemoryViewModel.EditTarget) {
        let live = content(for: target)
        guard target == selectedFile else {
            // Background file: only the untouched ones track disk.
            if stashedDrafts[target] == nil || stashedDrafts[target]?.draft == stashedDrafts[target]?.baseline {
                stashedDrafts[target] = (live, live)
            }
            return
        }
        guard isDirty else {
            syncDraftFromContent()
            return
        }
        if live != baseline { hasConflict = true }
    }

    private func discardEdits() {
        syncDraftFromContent()
    }

    /// Reload the disk copy, discarding the draft. The conflict resolution
    /// that loses your edits — matched by `overwrite()`, which loses theirs.
    private func reloadFromDisk() {
        let target = selectedFile
        Task {
            let disk = await viewModel.reload(target)
            switch target {
            case .memory: viewModel.memoryContent = disk
            case .user:   viewModel.userContent = disk
            }
            guard target == selectedFile else { return }
            baseline = disk
            draftText = disk
            hasConflict = false
            saveError = nil
        }
    }

    private func save(force: Bool = false) {
        let target = selectedFile
        let text = draftText
        let base = baseline
        Task {
            let outcome = await viewModel.save(text, target: target, baseline: base, force: force)
            guard target == selectedFile else { return }
            switch outcome {
            case .saved:
                // Advance the baseline BEFORE publishing, so the observer that
                // fires on the publish sees a clean buffer.
                baseline = text
                hasConflict = false
                saveError = nil
                stashedDrafts[target] = (text, text)
                switch target {
                case .memory: viewModel.memoryContent = text
                case .user:   viewModel.userContent = text
                }
            case .conflict(let onDisk):
                hasConflict = true
                // Keep the draft; move nothing. The banner offers both exits.
                switch target {
                case .memory: viewModel.memoryContent = onDisk
                case .user:   viewModel.userContent = onDisk
                }
                saveError = "\(fileMeta(target).filename) changed on disk since you started editing. Reload to take the new version (your edits are discarded), or overwrite it with yours."
            }
        }
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
