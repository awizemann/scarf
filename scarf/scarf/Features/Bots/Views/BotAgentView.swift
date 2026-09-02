import SwiftUI
import ScarfCore
import ScarfDesign

/// P1's `agent` slot: what this bot's AGENT is configured with — its model
/// pin, its `SOUL.md`, and the skills / toolsets / MCP servers it loads.
///
/// Deliberately calm. This is a configuration surface, not a dashboard: no
/// live counters, no status polling, no charts. Each group states what is
/// true, offers the one write Hermes actually supports for it, and says so
/// plainly where no write exists.
struct BotAgentView: View {
    @Bindable var viewModel: BotAgentViewModel

    @State private var showModelPicker = false
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            modelGroup
            soulGroup
            skillsGroup
            toolsetsGroup
            mcpGroup
        }
        .onAppear { viewModel.loadIfNeeded() }
        // The capability probe answers asynchronously, so the first render
        // can precede it — same race `BotsView`/`CronView` handle.
        .onChange(of: viewModel.hasBotMode) { _, hasBotMode in
            if hasBotMode { viewModel.load(force: true) }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                initialProvider: viewModel.config?.provider.pinned ?? "",
                initialModel: viewModel.config?.model.pinned ?? "",
                initialBaseURL: viewModel.config?.modelBaseURL ?? "",
                onSelect: { model, provider in
                    showModelPicker = false
                    viewModel.setModelPin(model: model, provider: provider)
                },
                onCancel: { showModelPicker = false }
            )
        }
        .confirmationDialog(
            "Use Hermes' default model for this bot?",
            isPresented: $showClearConfirm
        ) {
            Button("Clear Pin", role: .destructive) { viewModel.clearModelPin() }
            Button("Cancel", role: .cancel) { showClearConfirm = false }
        } message: {
            Text("Removes model.default and model.provider from this bot's config.yaml. The bot then runs on Hermes' built-in default — profiles don't inherit the main profile's model, so this won't fall back to whatever your main profile uses.")
        }
    }

    // MARK: - Header + shared error

    @ViewBuilder
    private func group<Content: View>(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if let subtitle {
                ScarfSectionHeader(title, subtitle: subtitle)
            } else {
                ScarfSectionHeader(title)
            }
            ScarfCard(padding: ScarfSpace.s3) {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    content()
                }
            }
        }
    }

    /// Verbatim CLI text — `hermes config set` / `tools enable` print the
    /// remedy, and a paraphrase would lose it.
    private func failure(_ text: String, label: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.danger)
                .accessibilityHidden(true)
            Text(text)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.danger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(text)")
    }

    /// Static copy — `LocalizedStringKey` so the literal is extraction-ready.
    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .scarfStyle(.footnote)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Copy that interpolates host state (a path, an endpoint). Deliberately
    /// a separate entry point: `Text(String)` binds the verbatim overload, so
    /// mixing the two under one name would silently make literals
    /// unextractable.
    private func noteVerbatim(_ text: String) -> some View {
        Text(text)
            .scarfStyle(.footnote)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Model

    private var modelGroup: some View {
        group("Model", subtitle: "Pinned in this bot's own config.yaml") {
            HStack(alignment: .top, spacing: ScarfSpace.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.modelSummary)
                        .scarfStyle(.bodyEmph)
                        .foregroundStyle(modelSummaryColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    switch viewModel.modelPinState {
                    case .hermesDefault:
                        note("Nothing is pinned, so this bot runs on Hermes' built-in default. Profiles don't inherit the main profile's model — pinning here changes only this bot.")
                    case .unreadable:
                        note("Scarf couldn't parse this file, so it can't tell you whether a model is pinned. Changing it from here is disabled until the file reads cleanly.")
                    case .pinned, .unknown:
                        EmptyView()
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: ScarfSpace.s2) {
                    if viewModel.isPinBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Change Model…") { showModelPicker = true }
                        .buttonStyle(ScarfPrimaryButton())
                        .disabled(!viewModel.canEditConfig || viewModel.isPinBusy)
                        .accessibilityLabel("Change the model pinned for this bot")
                    if viewModel.isPinned {
                        Button("Use Hermes Default") { showClearConfirm = true }
                            .buttonStyle(ScarfGhostButton())
                            .disabled(!viewModel.canEditConfig || viewModel.isPinBusy)
                            .accessibilityLabel("Clear this bot's model pin and use Hermes' default")
                    }
                }
            }
            // A bot pinned to a local server also has `model.base_url`, which
            // the picker's Local tab writes as one payload. That tab is only
            // offered when a host can persist the whole payload, and P0 has
            // no per-bot base_url writer — so it stays off here, and the
            // endpoint is shown rather than silently left out of the picker.
            if let baseURL = viewModel.config?.modelBaseURL, !baseURL.isEmpty {
                noteVerbatim("This bot talks to a local server at \(baseURL). Changing the model here keeps that endpoint; edit model.base_url in the bot's config.yaml to move it.")
            }
            if let path = viewModel.config?.configPath {
                Text(path)
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .textSelection(.enabled)
                    .accessibilityLabel("Configuration file: \(path)")
            }
            if let errorMessage = viewModel.errorMessage {
                failure(errorMessage, label: "Configuration error")
            }
        }
    }

    private var modelSummaryColor: Color {
        switch viewModel.modelPinState {
        case .unreadable: return ScarfColor.danger
        case .hermesDefault, .unknown: return ScarfColor.foregroundMuted
        case .pinned: return ScarfColor.foregroundPrimary
        }
    }

    // MARK: - SOUL.md

    private var soulGroup: some View {
        group("SOUL.md", subtitle: "This bot's identity prompt") {
            if viewModel.soulUnreadable {
                failure(
                    viewModel.soulError ?? "Couldn't read \(viewModel.soulPath).",
                    label: "SOUL.md error"
                )
            } else {
                if !viewModel.soulExists && !viewModel.isSoulDirty {
                    note("This bot has no SOUL.md yet. Hermes loads it as the first thing in the agent's system prompt — who the bot is, how it should behave, what it should never do. Write one below and save to create it.")
                }
                TextEditor(text: $viewModel.soulText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(ScarfColor.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous))
                    .disabled(!viewModel.hasLoadedSoul || viewModel.isSavingSoul)
                    .accessibilityLabel("SOUL.md for this bot")

                HStack(spacing: ScarfSpace.s2) {
                    Text(byteCountText)
                        .scarfStyle(.footnote)
                        .foregroundStyle(viewModel.soulOverLimit ? ScarfColor.danger : ScarfColor.foregroundFaint)
                        .accessibilityLabel(byteCountText)
                    if viewModel.isSoulDirty {
                        ScarfBadge("unsaved", kind: .warning)
                    }
                    Spacer(minLength: 0)
                    if viewModel.isSavingSoul { ProgressView().controlSize(.small) }
                    if viewModel.soulConflict {
                        Button("Reload from Disk") { viewModel.discardSoulAndReload() }
                            .buttonStyle(ScarfGhostButton())
                            .accessibilityLabel("Discard your edits and reload SOUL.md from disk")
                        Button("Overwrite") { viewModel.saveSoul(force: true) }
                            .buttonStyle(ScarfDestructiveButton())
                            .accessibilityLabel("Overwrite the changed SOUL.md with your edits")
                    } else {
                        Button("Revert") { viewModel.revertSoul() }
                            .buttonStyle(ScarfGhostButton())
                            .disabled(!viewModel.isSoulDirty || viewModel.isSavingSoul)
                            .accessibilityLabel("Discard unsaved changes to SOUL.md")
                        Button("Save") { viewModel.saveSoul() }
                            .buttonStyle(ScarfPrimaryButton())
                            .disabled(!viewModel.canSaveSoul)
                            .accessibilityLabel("Save SOUL.md")
                    }
                }
                if let soulError = viewModel.soulError {
                    failure(soulError, label: "SOUL.md error")
                }
            }
            Text(viewModel.soulPath)
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .textSelection(.enabled)
                .accessibilityLabel("SOUL.md path: \(viewModel.soulPath)")
        }
    }

    private var byteCountText: String {
        let limitKB = viewModel.soulByteLimit / 1024
        if viewModel.soulOverLimit {
            return "\(viewModel.soulByteCount) bytes — over the \(limitKB) KB limit, so this can't be saved."
        }
        return "\(viewModel.soulByteCount) of \(viewModel.soulByteLimit) bytes"
    }

    // MARK: - Skills

    private var skillsGroup: some View {
        group("Skills", subtitle: "Read-only at this Hermes version") {
            if viewModel.disabledSkills.isEmpty {
                note("No skills are switched off for this bot — it loads everything installed in its profile.")
            } else {
                ForEach(viewModel.disabledSkills, id: \.self) { skill in
                    HStack(spacing: ScarfSpace.s2) {
                        Image(systemName: "circle.slash")
                            .foregroundStyle(ScarfColor.foregroundFaint)
                            .accessibilityHidden(true)
                        Text(skill)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                        ScarfBadge("off", kind: .neutral)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Skill \(skill) is switched off for this bot")
                }
            }
            if !viewModel.canWriteSkillEnablement {
                note("Switching a skill on or off isn't available at this Hermes version — there's no command for it, and the setting is a list Scarf can't write safely. Edit skills.disabled in this bot's config.yaml directly.")
            }
        }
    }

    // MARK: - Toolsets

    private var toolsetsGroup: some View {
        group("Toolsets", subtitle: "What this bot can do on the command line") {
            if let toolsetsError = viewModel.toolsetsError {
                failure(toolsetsError, label: "Toolset error")
            } else if viewModel.toolsets.isEmpty {
                if viewModel.isLoading {
                    note("Reading this bot's toolsets…")
                } else {
                    note("Hermes reported no toolsets for this bot.")
                }
            } else {
                ForEach(viewModel.toolsets) { toolset in
                    toolsetRow(toolset)
                }
            }
        }
    }

    private func toolsetRow(_ toolset: HermesToolset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ScarfSpace.s2) {
                Text(verbatim: toolset.icon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: toolset.name)
                        .scarfStyle(.bodyEmph)
                    if !toolset.description.isEmpty, toolset.description != toolset.name {
                        Text(verbatim: toolset.description)
                            .scarfStyle(.footnote)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if viewModel.busyToolsets.contains(toolset.name) {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { toolset.enabled },
                    set: { viewModel.setToolset(toolset, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!viewModel.canEditConfig || viewModel.busyToolsets.contains(toolset.name))
                .accessibilityLabel("Toolset \(toolset.name)")
                .accessibilityValue(toolset.enabled ? "on" : "off")
            }
            if let rowError = viewModel.rowErrors[toolset.name] {
                failure(rowError, label: "Toolset \(toolset.name)")
            }
        }
    }

    // MARK: - MCP

    private var mcpGroup: some View {
        group("MCP servers", subtitle: "Configured in this bot's config.yaml") {
            if viewModel.mcpServers.isEmpty {
                note("This bot has no MCP servers configured. Add one with hermes mcp add while the bot's profile is active.")
            } else {
                ForEach(viewModel.mcpServers) { server in
                    mcpRow(server)
                }
                note("A server with no enabled: setting is ON — that's Hermes' default, not a choice anyone made. Switching it off writes the setting explicitly.")
            }
        }
    }

    private func mcpRow(_ server: BotMCPServerState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ScarfSpace.s2) {
                Text(verbatim: server.name)
                    .scarfStyle(.bodyEmph)
                if server.origin == .hermesDefault {
                    ScarfBadge("on by default", kind: .neutral)
                }
                Spacer(minLength: 0)
                if viewModel.busyMCPServers.contains(server.name) {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { server.isEnabled },
                    set: { viewModel.setMCPServer(server, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!viewModel.canEditConfig || viewModel.busyMCPServers.contains(server.name))
                .accessibilityLabel("MCP server \(server.name)")
                .accessibilityValue(mcpAccessibilityValue(server))
            }
            if let rowError = viewModel.rowErrors[server.name] {
                failure(rowError, label: "MCP server \(server.name)")
            }
        }
    }

    private func mcpAccessibilityValue(_ server: BotMCPServerState) -> String {
        switch (server.isEnabled, server.origin) {
        case (true, .hermesDefault): return "on, by Hermes' default"
        case (true, .pinned):        return "on"
        case (false, _):             return "off"
        }
    }
}
