import SwiftUI
import ScarfCore
import ScarfDesign

/// Installed skill detail. Shows location + required-config warning
/// banner + file picker + content viewer. Edit and Uninstall buttons
/// live in the toolbar.
///
/// v2.5 surfaces three Hermes v0.11+ pieces here:
/// - Spotify info row (when this is the spotify skill) — points users
///   back to Mac for the OAuth flow.
/// - design-md `npx` prereq banner — flagged when Node.js isn't on
///   the host's PATH.
/// - SKILL.md frontmatter chip rows (`allowed_tools` / `related_skills`
///   / `dependencies`) — populated by `SkillsScanner` from the file's
///   YAML frontmatter, hidden when nil.
struct SkillDetailView: View {
    let skill: HermesSkill
    @Bindable var vm: SkillsViewModel

    @Environment(\.serverContext) private var serverContext
    @State private var showEditor: Bool = false
    /// design-md npx probe result. Refetched per-skill via .task(id:).
    @State private var npxStatus: SkillPrereqService.Status?

    var body: some View {
        List {
            Section("Location") {
                LabeledContent("Category", value: skill.category)
                Text(skill.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .textSelection(.enabled)
                if !skill.enabled {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Disabled").font(.callout.weight(.medium))
                            Text("This skill is in `skills.disabled` in `~/.hermes/config.yaml`. Hermes won't load it. Re-enable from the Mac app's Skills config UI or with `hermes skills config`.")
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "circle.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                if skill.pinned {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pinned by curator").font(.callout.weight(.medium))
                            Text("The autonomous curator won't auto-archive or rewrite this skill. Unpin from the Curator screen.")
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(ScarfColor.accent)
                    }
                }
            }
            .listRowBackground(ScarfColor.backgroundSecondary)

            // v2.5 design-md prereq banner. Only when this is the
            // design-md skill AND `which npx` came back missing.
            if skill.name.lowercased() == "design-md",
               case .missing(let hint) = npxStatus {
                Section("Prerequisite missing") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("`npx` not found on the Hermes host.")
                                .font(.callout.weight(.medium))
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(ScarfColor.backgroundSecondary)
            }

            // v2.5 Spotify auth note. iOS doesn't run the OAuth flow
            // in-app (phones + browser callbacks are awkward); points
            // users at the Mac sheet or shell. Once authed, the iOS
            // skill picks up the credential from ~/.hermes/auth.json.
            if skill.name.lowercased() == "spotify" {
                Section("Authentication") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Spotify needs OAuth")
                                .font(.callout.weight(.medium))
                            Text("Run `hermes auth spotify` from the Scarf macOS app or a shell — it opens your browser to complete the OAuth flow. Once authorised, this skill picks up the credentials from `~/.hermes/auth.json` automatically.")
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "music.note")
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(ScarfColor.backgroundSecondary)
            }

            // v2.5 SKILL.md frontmatter chip rows. Each section
            // hides itself when its corresponding HermesSkill field
            // is nil — old skills without v0.11 frontmatter show
            // none of these.
            if let tools = skill.allowedTools, !tools.isEmpty {
                Section("Allowed tools") {
                    chipRow(tools)
                }
                .listRowBackground(ScarfColor.backgroundSecondary)
            }
            if let related = skill.relatedSkills, !related.isEmpty {
                Section("Related skills") {
                    chipRow(related)
                }
                .listRowBackground(ScarfColor.backgroundSecondary)
            }
            if let deps = skill.dependencies, !deps.isEmpty {
                Section("Dependencies") {
                    chipRow(deps)
                }
                .listRowBackground(ScarfColor.backgroundSecondary)
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
                                .foregroundStyle(ScarfColor.foregroundMuted)
                            ForEach(vm.missingConfig, id: \.self) { key in
                                Text("• \(key)")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(ScarfColor.backgroundSecondary)
            }

            if !skill.files.isEmpty {
                Section("Files") {
                    ForEach(skill.files, id: \.self) { file in
                        Button {
                            Task { await vm.selectFile(file) }
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
                        .listRowBackground(ScarfColor.backgroundSecondary)
                    }
                }
            }

            if vm.selectedFileName != nil {
                Section("Content") {
                    // AX H5 / iOS refusal parity with the Mac. The guarded
                    // reader REFUSES to hand back text for a file it could
                    // not read, and `skillContent` is then empty — which
                    // this screen used to render as "(empty file)": a
                    // confident statement about a file nobody managed to
                    // read, over which Save would then have been offered.
                    // `contentError` distinguishes the two, so check it
                    // FIRST and say what actually happened.
                    //
                    // The read itself is a detached task (GW-F6): over SSH
                    // that is several timeout-bounded spawns, during which
                    // `skillContent` is deliberately blank and `contentError`
                    // is nil. Without this row that in-flight state rendered
                    // as "(empty file)" — the same confident lie the refusal
                    // branch below exists to avoid. Same idiom as
                    // `InstalledSkillsListView`'s scan spinner.
                    if vm.isLoadingContent {
                        ProgressView(String(localized: "Reading file…"))
                            .font(.caption)
                            .accessibilityLabel(
                                String(localized: "Reading the selected skill file")
                            )
                    } else if let contentError = vm.contentError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text(contentError)
                                .font(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(String(localized: "Couldn’t read this file: \(contentError)"))
                    } else if vm.skillContent.isEmpty {
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
                .listRowBackground(ScarfColor.backgroundSecondary)
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Selecting the skill (re)loads its main file content +
            // missingConfig diagnostics. Idempotent on re-appears.
            await vm.selectSkill(skill)
        }
        .task(id: skill.id) {
            // v2.5: probe `npx` only when this is the design-md skill —
            // the only skill that surfaces a host-side prereq today.
            // Cheap (single SSH `which`); not cached across navigations
            // so users see a fresh result if they install Node and come
            // back.
            guard skill.name.lowercased() == "design-md" else {
                npxStatus = nil
                return
            }
            let svc = SkillPrereqService(context: serverContext)
            npxStatus = await svc.probe(binary: "npx")
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
                    // Disabled rather than hidden, and the notice in the
                    // Content section above explains why: `startEditing()`
                    // guard-returns without the load proof, so tapping this
                    // opened a blank editor over a file that exists, and
                    // Save then silently no-opped (the write was correctly
                    // refused; the UX was silence).
                    .disabled(!vm.canEditSelectedFile)
                    .accessibilityHint(
                        vm.canEditSelectedFile
                            ? Text("")
                            : Text("Editing is off because this file couldn’t be read.")
                    )
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

    /// Render a list of strings as wrapping pill chips (v2.5 SKILL.md
    /// frontmatter sections). Uses the shared `FlowLayout` from
    /// `Components/FlowLayout.swift` so chips wrap onto multiple lines
    /// on iPhone-narrow screens.
    @ViewBuilder
    private func chipRow(_ items: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.monospaced())
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}
