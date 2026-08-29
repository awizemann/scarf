import SwiftUI
import ScarfCore
import ScarfDesign

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
    /// Sheet for v0.12 direct-URL skill install. Capability-gated so
    /// the trigger button only appears on hosts that support it.
    @State private var showInstallFromURLSheet = false
    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var currentTab: Tab = .installed
    /// Skill awaiting confirmation for a destructive `--force` update.
    @State private var forceUpdateTarget: String?

    init(context: ServerContext) {
        _viewModel = State(initialValue: SkillsViewModel(context: context))
    }


    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case bundles = "Bundles"
        case hub = "Browse Hub"
        case updates = "Updates"
        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .installed: return "Installed"
            case .bundles: return "Bundles"
            case .hub: return "Browse Hub"
            case .updates: return "Updates"
            }
        }
    }

    /// The tabs to render. `.bundles` only appears when the connected
    /// host advertises Hermes v0.15 skill bundles — pre-v0.15 hosts
    /// don't have `~/.hermes/skill-bundles/` so the surface would always
    /// be empty.
    private var visibleTabs: [Tab] {
        let hasBundles = capabilitiesStore?.capabilities.hasSkillBundles ?? false
        return Tab.allCases.filter { $0 != .bundles || hasBundles }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Skills",
                subtitle: "Pre-packaged prompt collections the agent can call into. \(viewModel.totalSkillCount) installed."
            ) {
                HStack(spacing: 6) {
                    Button {
                        Task { await viewModel.reloadSkills() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ScarfGhostButton())
                    .help("Re-scan ~/.hermes/skills/ and pick up edits without restarting Hermes")

                    if capabilitiesStore?.capabilities.hasSkillURLInstall ?? false {
                        Button {
                            showInstallFromURLSheet = true
                        } label: {
                            Label("Install from URL…", systemImage: "link.badge.plus")
                        }
                        .buttonStyle(ScarfPrimaryButton())
                    }
                }
            }
            modePicker
            // v2.5 "What's New" pill — only renders when the diff has
            // changes against a non-empty prior snapshot (first launch
            // is silent so users aren't drowned in "everything is
            // new!" noise).
            //
            // Issue #78: keep the pill scoped to the Installed tab.
            // It describes local file deltas in the installed-skill
            // tree; surfacing it above the Hub or Updates tab read as
            // a contradiction with the Updates body's separate
            // upstream-version check.
            if currentTab == .installed,
               let diff = snapshotDiff,
               diff.hasChanges,
               !diff.previousSnapshotEmpty {
                whatsNewPill(diff: diff)
            }
            Divider()
            switch currentTab {
            case .installed: installedContent
            case .bundles:   bundlesContent
            case .hub:       hubContent
            case .updates:   updatesContent
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Skills")
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
        .sheet(isPresented: $showInstallFromURLSheet) {
            InstallFromURLSheet(viewModel: viewModel)
        }
    }

    /// Snapshot service scoped to this server AND its selected Hermes
    /// profile (#120). The profile is derived from `paths.home`: a server
    /// whose home points at `<root>/profiles/<name>` keys its baseline per
    /// profile; a local/root home yields a nil profile → the unchanged
    /// per-server key. Without this, switching profiles would diff one
    /// profile's skills against another's baseline ("What's New" lies).
    private var snapshotService: SkillSnapshotService {
        SkillSnapshotService(
            serverID: serverContext.id,
            profile: HermesProfileScope.profileName(forHome: serverContext.paths.home)
        )
    }

    /// Compute the snapshot diff against the active server's last-seen
    /// state. On a first-ever load (empty snapshot) we silently mark
    /// the current set as seen so the next load shows real deltas.
    private func recomputeSnapshotDiff() {
        let allSkills = viewModel.categories.flatMap(\.skills)
        let svc = snapshotService
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
                snapshotService.markSeen(viewModel.categories.flatMap(\.skills))
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
                ForEach(visibleTabs) { tab in
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
                        skillRow(skill)
                            .tag(skill.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Sidebar row with enabled/disabled visual state + pin badge.
    /// Disabled skills render at .secondary opacity so the user can see
    /// they exist but Hermes won't load them.
    @ViewBuilder
    private func skillRow(_ skill: HermesSkill) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "lightbulb")
                .frame(width: 14)
                .foregroundStyle(skill.enabled ? .primary : .secondary)
            Text(skill.name)
                .foregroundStyle(skill.enabled ? .primary : .secondary)
                .strikethrough(!skill.enabled, color: .secondary)
            Spacer(minLength: 0)
            if skill.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(ScarfColor.accent)
                    .help("Pinned by curator")
            }
            if !skill.enabled {
                Text("OFF")
                    .scarfStyle(.captionUppercase)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(ScarfColor.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .help("Disabled in skills.disabled — Hermes won't load this one")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(skillRowLabel(skill))
    }

    /// Spoken row label: skill name first, then the state the icons and
    /// badge carry visually (pinned, disabled).
    private func skillRowLabel(_ skill: HermesSkill) -> String {
        var parts = [skill.name]
        if skill.pinned { parts.append(String(localized: "pinned")) }
        if !skill.enabled { parts.append(String(localized: "disabled")) }
        return parts.joined(separator: ", ")
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
                    // v0.13 `[[as_document]]` directive — informational
                    // only. Rendered when the skill body contains the
                    // marker AND the host advertises Google Chat support
                    // (cheap proxy: the directive shipped in v0.13
                    // alongside Google Chat — see WS-5 plan §Q5/Q6).
                    if (capabilitiesStore?.capabilities.hasGoogleChatPlatform ?? false),
                       skillContentMentionsAsDocument {
                        asDocumentInfoRow
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

    /// Returns true when the loaded skill body contains the v0.13
    /// `[[as_document]]` directive. Substring scan over `skillContent`
    /// — `[[as_document]]` is a literal token Hermes pattern-matches at
    /// runtime, not a frontmatter key, so the body is the right place
    /// to look. // TODO(WS-5-Q6): if Hermes ever moves the directive
    /// into frontmatter, switch to `SkillFrontmatterParser` instead.
    private var skillContentMentionsAsDocument: Bool {
        viewModel.skillContent.contains("[[as_document]]")
    }

    /// Compact informational row about the `[[as_document]]` directive.
    /// Does not block any action — it's a label so users understand why
    /// images in the skill might land as document attachments on certain
    /// platforms (Google Chat, Microsoft Teams) rather than inline.
    private var asDocumentInfoRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.badge.gearshape")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Document-attachment directive present (v0.13+)")
                    .font(.caption.bold())
                Text("Media in this skill marked with `[[as_document]]` is sent as document attachments instead of inline images on platforms that distinguish (Google Chat, Microsoft Teams).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    /// Spoken row label for a hub search result: name, registry it came
    /// from, the fully-qualified identifier used to install it, then the
    /// description. The description is part of the label because
    /// `.combine` collapses the row into a single element — leaving it
    /// out would make it unreachable to VoiceOver.
    private func hubRowLabel(_ hub: HermesHubSkill) -> String {
        var parts = [hub.name]
        if !hub.source.isEmpty { parts.append(String(localized: "from \(hub.source)")) }
        parts.append(hub.identifier)
        if !hub.description.isEmpty { parts.append(hub.description) }
        return parts.joined(separator: ", ")
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel(hubRowLabel(hub))
            Spacer()
            Button {
                viewModel.installHubSkill(hub)
            } label: {
                Label("Install", systemImage: "arrow.down.to.line")
            }
            .controlSize(.small)
            .accessibilityLabel("Install \(hub.name)")
            .disabled(viewModel.isHubLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    // MARK: - Bundles

    /// v0.15 skill-bundles surface. Read-only list of the bundle YAMLs
    /// found in `~/.hermes/skill-bundles/`. Each card shows the bundle
    /// name, optional description, the member-skill chip row, and the
    /// `/<slug>` command that invokes it.
    private var bundlesContent: some View {
        Group {
            if viewModel.bundles.isEmpty {
                ContentUnavailableView(
                    "No Skill Bundles",
                    systemImage: "square.stack.3d.up",
                    description: Text("Bundles group several skills under one `/<name>` command. Create them with `hermes bundles create`; they live in ~/.hermes/skill-bundles/.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ScarfSpace.s3) {
                        ForEach(viewModel.bundles) { bundle in
                            bundleCard(bundle)
                        }
                    }
                    .padding(ScarfSpace.s4)
                }
            }
        }
    }

    private func bundleCard(_ bundle: HermesSkillBundle) -> some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                HStack(spacing: ScarfSpace.s2) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(ScarfColor.accent)
                    Text(bundle.name)
                        .scarfStyle(.headline)
                    Spacer(minLength: 0)
                    ScarfBadge("/\(bundle.slug)", kind: .brand)
                }
                if let description = bundle.description, !description.isEmpty {
                    Text(description)
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !bundle.skills.isEmpty {
                    VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                        Text("\(bundle.skills.count) skill\(bundle.skills.count == 1 ? "" : "s")")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                        BundleChipFlowLayout(spacing: ScarfSpace.s1) {
                            ForEach(bundle.skills, id: \.self) { skill in
                                Text(skill)
                                    .scarfStyle(.caption)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                    .padding(.horizontal, ScarfSpace.s2)
                                    .padding(.vertical, 2)
                                    .background(ScarfColor.backgroundTertiary, in: Capsule())
                            }
                        }
                    }
                }
                if let instruction = bundle.instruction, !instruction.isEmpty {
                    VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                        Text("Instruction")
                            .scarfStyle(.captionUppercase)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                        Text(instruction)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            // Hermes v0.20.4+ leaves locally-edited skills alone. Empty
            // on older hosts (they never skip), so this section is
            // invisible there and the tab renders exactly as before.
            if !viewModel.skippedLocalEdits.isEmpty {
                keptLocalEditsSection
                Divider()
            }
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
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(update.identifier), update available, \(update.currentVersion) to \(update.availableVersion)"
                            )
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

    /// Skills the last "Update All" deliberately did not touch because
    /// the user has edited them on disk. The per-skill override re-runs
    /// `skills update <name> --force` for that one skill only — it is
    /// destructive, so it's never applied in bulk and only appears on
    /// hosts that understand `--force` in this sense (v0.20.4+).
    private var keptLocalEditsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(viewModel.skippedLocalEdits.count) skill(s) kept your local edits",
                systemImage: "pencil.and.outline"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)
            ForEach(viewModel.skippedLocalEdits, id: \.self) { name in
                HStack {
                    Text(name)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("\(name), local edits kept")
                    Spacer()
                    if capabilitiesStore?.capabilities.hasSkillsUpdateForce ?? false {
                        Button("Update anyway…") {
                            forceUpdateTarget = name
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Update \(name) anyway, discarding local edits")
                    }
                }
            }
            Text("Updating these would overwrite your edits, so Hermes skipped them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .alert(
            "Discard local edits to \(forceUpdateTarget ?? "")?",
            isPresented: Binding(
                get: { forceUpdateTarget != nil },
                set: { if !$0 { forceUpdateTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { forceUpdateTarget = nil }
            Button("Update & Discard", role: .destructive) {
                if let name = forceUpdateTarget {
                    viewModel.forceUpdateSkill(name)
                }
                forceUpdateTarget = nil
            }
        } message: {
            Text("The upstream version will replace your edited copy. This can't be undone.")
        }
    }
}

/// Wrapping chip layout for a bundle's member-skill list. Custom layout
/// keeps the wrap behaviour predictable across window widths without a
/// fixed-column `LazyVGrid`. Mirrors the `FlowLayout` used by CuratorView
/// (scoped privately there; copied here to avoid a cross-feature import).
private struct BundleChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
