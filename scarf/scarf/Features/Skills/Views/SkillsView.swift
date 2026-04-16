import SwiftUI

struct SkillsView: View {
    @State private var viewModel = SkillsViewModel()
    @State private var currentTab: Tab = .installed

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case hub = "Browse Hub"
        case updates = "Updates"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            Divider()
            switch currentTab {
            case .installed: installedContent
            case .hub:       hubContent
            case .updates:   updatesContent
            }
        }
        .navigationTitle("Skills (\(viewModel.totalSkillCount))")
        .onAppear { viewModel.load() }
    }

    private var modePicker: some View {
        HStack {
            Picker("", selection: $currentTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Spacer()
            if let msg = viewModel.hubMessage {
                Label(msg, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.isHubLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Installed

    private var installedContent: some View {
        HSplitView {
            skillsList
                .frame(minWidth: 250, idealWidth: 300)
            skillDetail
                .frame(minWidth: 400)
        }
        .searchable(text: $viewModel.searchText, prompt: "Filter skills...")
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
                            Button("Uninstall", role: .destructive) {
                                viewModel.uninstallHubSkill(skill.id)
                            }
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

    // MARK: - Hub

    private var hubContent: some View {
        VStack(spacing: 0) {
            hubToolbar
            Divider()
            if viewModel.hubResults.isEmpty {
                ContentUnavailableView(
                    "Browse the Hub",
                    systemImage: "books.vertical",
                    description: Text("Search or browse skills published to registries like skills.sh, GitHub, and the official hub.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.hubResults) { hub in
                            hubRow(hub)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var hubToolbar: some View {
        HStack(spacing: 8) {
            TextField("Search registries", text: $viewModel.hubQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.searchHub() }
            Picker("Source", selection: $viewModel.hubSource) {
                ForEach(viewModel.hubSources, id: \.self) { src in
                    Text(src).tag(src)
                }
            }
            .frame(maxWidth: 160)
            Button("Search") { viewModel.searchHub() }
                .controlSize(.small)
            Button("Browse") { viewModel.browseHub() }
                .controlSize(.small)
        }
        .padding()
    }

    private func hubRow(_ hub: HermesHubSkill) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hub.name)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                    if !hub.source.isEmpty {
                        Text(hub.source)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
                Text(hub.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !hub.description.isEmpty {
                    Text(hub.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer()
            Button {
                viewModel.installHubSkill(hub)
            } label: {
                Label("Install", systemImage: "arrow.down.to.line")
            }
            .controlSize(.small)
            .disabled(viewModel.isHubLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    // MARK: - Updates

    private var updatesContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Check for Updates") { viewModel.checkForUpdates() }
                    .controlSize(.small)
                if !viewModel.updates.isEmpty {
                    Button("Update All") { viewModel.updateAll() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            Divider()
            if viewModel.updates.isEmpty {
                ContentUnavailableView(
                    "No Updates",
                    systemImage: "checkmark.circle",
                    description: Text("All installed hub skills are up to date.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.updates) { update in
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(update.identifier)
                                        .font(.system(.body, design: .monospaced, weight: .medium))
                                    Text("\(update.currentVersion) → \(update.availableVersion)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.3))
                        }
                    }
                    .padding()
                }
            }
        }
    }
}
