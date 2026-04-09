import SwiftUI

struct SkillsView: View {
    @State private var viewModel = SkillsViewModel()

    var body: some View {
        HSplitView {
            skillsList
                .frame(minWidth: 250, idealWidth: 300)
            skillDetail
                .frame(minWidth: 400)
        }
        .navigationTitle("Skills (\(viewModel.totalSkillCount))")
        .searchable(text: $viewModel.searchText, prompt: "Filter skills...")
        .onAppear { viewModel.load() }
    }

    private var skillsList: some View {
        List(selection: Binding(
            get: { viewModel.selectedSkill?.id },
            set: { id in
                if let id {
                    for category in viewModel.filteredCategories {
                        if let skill = category.skills.first(where: { $0.id == id }) {
                            viewModel.selectSkill(skill)
                            return
                        }
                    }
                }
                viewModel.selectedSkill = nil
                viewModel.skillContent = ""
            }
        )) {
            ForEach(viewModel.filteredCategories) { category in
                Section(category.name) {
                    ForEach(category.skills) { skill in
                        Label(skill.name, systemImage: "lightbulb")
                            .tag(skill.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var skillDetail: some View {
        if let skill = viewModel.selectedSkill {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(skill.name)
                        .font(.title2.bold())
                    HStack {
                        Label(skill.category, systemImage: "folder")
                        Label("\(skill.files.count) files", systemImage: "doc")
                        if !skill.requiredConfig.isEmpty {
                            Label("\(skill.requiredConfig.count) required config", systemImage: "gearshape")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !viewModel.missingConfig.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Missing required config:")
                                    .font(.caption.bold())
                                Text(viewModel.missingConfig.joined(separator: ", "))
                                    .font(.caption.monospaced())
                            }
                        }
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    if !skill.files.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Files")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ForEach(skill.files, id: \.self) { file in
                                Button {
                                    viewModel.selectFile(file)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: viewModel.selectedFileName == file ? "doc.fill" : "doc")
                                            .font(.caption)
                                        Text(file)
                                            .font(.caption.monospaced())
                                    }
                                    .foregroundStyle(viewModel.selectedFileName == file ? .primary : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !viewModel.skillContent.isEmpty {
                        Divider()
                        HStack {
                            Spacer()
                            Button("Edit") { viewModel.startEditing() }
                                .controlSize(.small)
                        }
                        if viewModel.isMarkdownFile {
                            MarkdownContentView(content: viewModel.skillContent)
                        } else {
                            Text(viewModel.skillContent)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .sheet(isPresented: $viewModel.isEditing) {
                skillEditorSheet
            }
        } else {
            ContentUnavailableView("Select a Skill", systemImage: "lightbulb", description: Text("Choose a skill from the list"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var skillEditorSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit \(viewModel.selectedFileName ?? "File")")
                    .font(.headline)
                Spacer()
                Button("Cancel") { viewModel.cancelEditing() }
                Button("Save") { viewModel.saveEdit() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            HSplitView {
                TextEditor(text: $viewModel.editText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                if viewModel.isMarkdownFile {
                    ScrollView {
                        MarkdownContentView(content: viewModel.editText)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
