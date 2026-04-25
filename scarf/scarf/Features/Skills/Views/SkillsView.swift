import SwiftUI
import ScarfCore

struct SkillsView: View {
    @State private var viewModel: SkillsViewModel
    @State private var showSpotifySignIn: Bool = false
    /// Result of the npx prereq probe for the design-md skill, when
    /// selected. Re-fetched on each skill change. Nil while the probe
    /// is in flight; populated with `.present` / `.missing(...)` /
    /// `.unknown(...)` on completion.
    @State private var designMdNpxStatus: SkillPrereqService.Status?
    /// Diff between the current skill list and the last-seen snapshot
    /// for the active server. Drives the v2.5 "What's New" pill at
    /// the top of the Skills list. Nil before first compute.
    @State private var snapshotDiff: SkillSnapshotDiff?
    @Environment(\.serverContext) private var serverContext
    @State private var currentTab: Tab = .installed

    init(context: ServerContext) {
        _viewModel = State(initialValue: SkillsViewModel(context: context))
    }


    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case hub = "Browse Hub"
        case updates = "Updates"
        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .installed: return "Installed"
            case .hub: return "Browse Hub"
            case .updates: return "Updates"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            // v2.5 "What's New" pill — only renders when the diff has
            // changes against a non-empty prior snapshot (first launch
            // is silent so users aren't drowned in "everything is
            // new!" noise).
            if let diff = snapshotDiff,
               diff.hasChanges,
               !diff.previousSnapshotEmpty {
                whatsNewPill(diff: diff)
            }
            Divider()
            switch currentTab {
            case .installed: installedContent
            case .hub:       hubContent
            case .updates:   updatesContent
            }
        }
        .navigationTitle("Skills (\(viewModel.totalSkillCount))")
        // SkillsViewModel.load() is async after the v2.5 ScarfCore
        // promotion. Wrap in a Task here so the existing onAppear
        // contract (fire-and-forget) keeps working without making
        // the Mac UI care about the new isolation.
        .onAppear {
            Task { await viewModel.load() }
        }
        // v2.5: re-probe `npx` whenever the selected skill changes;
        // only the design-md skill cares about the result, but binding
        // to the selection makes the probe automatic across switches.
        .onChange(of: viewModel.selectedSkill?.name) { _, newName in
            guard newName?.lowercased() == "design-md" else {
                designMdNpxStatus = nil
                return
            }
            designMdNpxStatus = nil
            let svc = SkillPrereqService(context: serverContext)
            Task { @MainActor in
                designMdNpxStatus = await svc.probe(binary: "npx")
            }
        }
        // Snapshot diff: recompute whenever the loaded skill list
        // changes. First-load with no prior snapshot silently primes
        // the snapshot — subsequent changes show the pill.
        .onChange(of: viewModel.totalSkillCount) { _, _ in
            recomputeSnapshotDiff()
        }
        .task {
            recomputeSnapshotDiff()
        }
    }

    /// Compute the snapshot diff against the active server's last-seen
    /// state. On a first-ever load (empty snapshot) we silently mark
    /// the current set as seen so the next load shows real deltas.
    private func recomputeSnapshotDiff() {
        let allSkills = viewModel.categories.flatMap(\.skills)
        let svc = SkillSnapshotService(serverID: serverContext.id)
        let diff = svc.diff(against: allSkills)
        if diff.previousSnapshotEmpty {
            // Silent prime — don't show the pill; just record what
            // we've seen so future diffs are honest.
            svc.markSeen(allSkills)
            snapshotDiff = nil
        } else {
            snapshotDiff = diff
        }
    }

    /// Tappable pill rendering "2 new, 4 updated since you last looked".
    /// Tap → mark current set as seen + dismiss the pill.
    private func whatsNewPill(diff: SkillSnapshotDiff) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(diff.label)
                .font(.callout)
            Spacer()
            Button("Mark as seen") {
                let svc = SkillSnapshotService(serverID: serverContext.id)
                svc.markSeen(viewModel.categories.flatMap(\.skills))
                snapshotDiff = nil
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.1))
    }

    private var modePicker: some View {
        HStack {
            Picker("", selection: $currentTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
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
                    // v2.5 Spotify auth affordance — only when this skill
                    // is the spotify one. We don't probe auth.json here
                    // (transport read is async); the button always shows
                    // and the sheet itself handles the "already signed in?"
                    // case (token present → succeeds immediately on retry).
                    if skill.name.lowercased() == "spotify" {
                        spotifyAuthRow
                    }
                    // v2.5 design-md prereq surface. The skill needs
                    // `npx` (Node.js 18+) on the host; show a yellow
                    // banner with an install hint when it's missing.
                    if skill.name.lowercased() == "design-md",
                       case .missing(let hint) = designMdNpxStatus {
                        designMdNpxBanner(hint: hint)
                    }
                    // v2.5 SKILL.md frontmatter chips. Render only the
                    // sections that are populated — old skills without
                    // this metadata show no extra rows.
                    if let tools = skill.allowedTools, !tools.isEmpty {
                        skillChipSection(title: "Allowed tools", items: tools)
                    }
                    if let related = skill.relatedSkills, !related.isEmpty {
                        skillChipSection(title: "Related skills", items: related)
                    }
                    if let deps = skill.dependencies, !deps.isEmpty {
                        skillChipSection(title: "Dependencies", items: deps)
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
            .sheet(isPresented: $showSpotifySignIn) {
                SpotifySignInSheet(onSignedIn: {
                    // No state to refresh in this view yet — chat picks
                    // up the new token on next session start. Keep the
                    // hook so a future "auth status" indicator can rebind.
                })
            }
        } else {
            ContentUnavailableView("Select a Skill", systemImage: "lightbulb", description: Text("Choose a skill from the list"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Render a labelled chip row for v2.5 SKILL.md frontmatter
    /// sections (allowed_tools, related_skills, dependencies). Items
    /// flow horizontally with wrapping; the row hides itself when
    /// there's nothing to show (caller already gates on `!isEmpty`).
    private func skillChipSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    /// Yellow banner surfaced on the design-md skill detail when the
    /// host's `npx` probe came back missing. Reuses the same color
    /// language as the missing-config banner.
    private func designMdNpxBanner(hint: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 2) {
                Text("`npx` not found on the Hermes host.")
                    .font(.caption.bold())
                Text(hint)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Renders the v2.5 Spotify auth row when the user has the
    /// `spotify` skill selected. Tapping opens `SpotifySignInSheet`
    /// which drives `hermes auth spotify` end-to-end in-app.
    private var spotifyAuthRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to Spotify")
                    .font(.callout.weight(.medium))
                Text("Authorise Hermes to control playback, search, and library actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In") { showSpotifySignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
