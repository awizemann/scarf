import SwiftUI
import ScarfCore

/// Installed skill detail. Shows location + required-config warning
/// banner + file picker + content viewer. Edit and Uninstall buttons
/// live in the toolbar.
struct SkillDetailView: View {
    let skill: HermesSkill
    @Bindable var vm: SkillsViewModel

    @State private var showEditor: Bool = false

    var body: some View {
        List {
            Section("Location") {
                LabeledContent("Category", value: skill.category)
                Text(skill.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !vm.missingConfig.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Required config not set")
                                .font(.callout)
                                .fontWeight(.semibold)
                            Text("Add these keys to ~/.hermes/config.yaml:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(vm.missingConfig, id: \.self) { key in
                                Text("• \(key)")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            if !skill.files.isEmpty {
                Section("Files") {
                    ForEach(skill.files, id: \.self) { file in
                        Button {
                            vm.selectFile(file)
                        } label: {
                            HStack {
                                Text(file)
                                    .font(.callout.monospaced())
                                Spacer()
                                if vm.selectedFileName == file {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .scarfGoCompactListRow()
                    }
                }
            }

            if vm.selectedFileName != nil {
                Section("Content") {
                    if vm.skillContent.isEmpty {
                        Text("(empty file)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if vm.isMarkdownFile {
                        Text(markdown(vm.skillContent))
                            .font(.callout)
                            .textSelection(.enabled)
                    } else {
                        Text(vm.skillContent)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .scarfGoListDensity()
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Selecting the skill (re)loads its main file content +
            // missingConfig diagnostics. Idempotent on re-appears.
            vm.selectSkill(skill)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if vm.selectedFileName != nil {
                    Button {
                        vm.startEditing()
                        showEditor = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                Menu {
                    Button(role: .destructive) {
                        vm.uninstallHubSkill(skill.id)
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            SkillEditorSheet(vm: vm, fileName: vm.selectedFileName ?? "")
        }
    }

    private func markdown(_ raw: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: raw, options: opts)) ?? AttributedString(raw)
    }
}
