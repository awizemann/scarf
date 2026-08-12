import SwiftUI
import ScarfCore

/// Auxiliary tab — the 8 sub-model tasks hermes delegates to cheaper models.
/// Each follows the same provider/model/base_url/api_key/timeout pattern.
///
/// Adds a per-task **Route through Nous Portal** toggle for Hermes v0.10.0+
/// subscribers. The toggle flips `auxiliary.<task>.provider` between `nous`
/// (subscription-routed) and `auto` (inherit main provider) — Hermes derives
/// the gateway routing from that single field; there is no separate
/// `use_gateway` key to write.
///
/// v0.12 dropped the `flush_memories` aux task on the server side and
/// added `curator` (the autonomous skill-maintenance review fork). The
/// Curator row only appears when `HermesCapabilities.hasCuratorAux` is
/// set; the Flush Memories row only appears when
/// `HermesCapabilities.hasFlushMemoriesAux` is set (inverse semantics —
/// `true` only on pre-v0.12 hosts where the task still exists). v0.11
/// users keep their edit surface; v0.12 users never see it.
struct AuxiliaryTab: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.serverContext) private var serverContext
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    @State private var subscription: NousSubscriptionState = .absent
    @State private var showNousSignIn: Bool = false

    // Keyed by the config path name — matches `auxiliary.<task>.*` in config.yaml.
    // Static base list; the v0.12-only `curator` row is appended at render
    // time when the target Hermes supports it.
    private let baseTasks: [(key: String, title: LocalizedStringKey, icon: String)] = [
        ("vision", "Vision", "eye"),
        ("web_extract", "Web Extract", "doc.richtext"),
        ("compression", "Compression", "arrow.down.right.and.arrow.up.left.circle"),
        ("session_search", "Session Search", "magnifyingglass"),
        ("skills_hub", "Skills Hub", "books.vertical"),
        ("approval", "Approval", "checkmark.seal"),
        ("mcp", "MCP", "puzzlepiece")
    ]

    private var tasks: [(key: String, title: LocalizedStringKey, icon: String)] {
        var t = baseTasks
        if capabilitiesStore?.capabilities.hasFlushMemoriesAux ?? false {
            t.append(("flush_memories", "Flush Memories", "trash.slash"))
        }
        if capabilitiesStore?.capabilities.hasCuratorAux ?? false {
            t.append(("curator", "Curator", "sparkles"))
        }
        return t
    }

    /// Aux task keys present in `config.yaml` but NOT in `tasks` —
    /// e.g. `auxiliary.summarization.provider` from older Hermes
    /// versions, or experimental tasks the user added by hand.
    /// Without surfacing these, a user whose config has
    /// `auxiliary.summarization.provider: nous` (where nous is no
    /// longer authenticated) sees the "5 toggles all off" Aux
    /// Models tab and concludes nothing's set — but Hermes
    /// crashes because it's still resolving the unknown task to
    /// a missing provider. Now those tasks render in a
    /// fall-through "Other tasks in config.yaml" section.
    private var unknownTasks: [String] {
        let known = Set(tasks.map(\.key))
        let found = Self.parseAuxTaskNames(from: viewModel.rawConfigYAML)
        return found.subtracting(known).sorted()
    }

    /// Walk the raw config.yaml for the top-level `auxiliary:` block
    /// and collect ONLY direct-child task names (not the leaf
    /// fields underneath them like `provider`, `model`, `api_key`).
    /// Static + `internal` so unit tests can drive it with fixture
    /// strings without standing up a SettingsViewModel.
    ///
    /// Handles both 2-space and 4-space indent styles. Tolerates
    /// blank lines and comments. Stops collecting when indent
    /// drops back to or below the `auxiliary:` line — same shape
    /// the YAML parser uses to decide block boundaries.
    static func parseAuxTaskNames(from yaml: String) -> Set<String> {
        var found: Set<String> = []
        var inAuxBlock = false
        var auxIndent = -1
        // Indent of the first task-name line we see inside the
        // block. Established lazily so we work with both 2- and
        // 4-space indentation. Once locked, only collect at this
        // exact indent — anything deeper is a leaf field.
        var taskIndent = -1
        for rawLine in yaml.components(separatedBy: "\n") {
            // Strip line-trailing CRs (Windows / SSH artifacts).
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.count - trimmed.count
            // Skip blanks + comments without resetting state.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !inAuxBlock {
                if trimmed.hasPrefix("auxiliary:") {
                    inAuxBlock = true
                    auxIndent = indent
                    taskIndent = -1
                }
                continue
            }
            // Out of the aux block when indent drops back to or
            // below auxIndent on a non-comment / non-blank line.
            if indent <= auxIndent {
                inAuxBlock = false
                taskIndent = -1
                continue
            }
            // First nested line inside the block: that indent
            // level is the task-name level for the rest of this
            // block.
            if taskIndent == -1 {
                taskIndent = indent
            }
            // Skip leaf fields — they live at indent > taskIndent.
            guard indent == taskIndent else { continue }
            // The line should look like `<key>:` or `<key>: <inline>`.
            // Match `<identifier>:` at the start to filter out
            // things like flow-style maps `[a, b]:` that aren't
            // task definitions.
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIdx].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty,
               key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                found.insert(key)
            }
        }
        return found
    }

    var body: some View {
        Text("Auxiliary tasks use separate, typically cheaper models. Leave Provider as `auto` to inherit the main provider.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

        ForEach(tasks, id: \.key) { task in
            SettingsSection(title: task.title, icon: task.icon) {
                auxRows(for: task.key)
            }
        }
        // Title generation (auxiliary.title_generation) — the sub-model
        // task that names new chat sessions. Ungated: the base block
        // predates version tracking. Only the `language` row is v0.18+.
        SettingsSection(title: "Title Generation", icon: "text.quote") {
            titleGenerationRows
        }
        // -- Hermes v0.13 additions ---------------------------------
        // Image-gen model picker. Hermes v0.13 honors `image_gen.model`
        // as a top-level YAML key; pre-v0.13 hosts ignore it silently.
        // Hide the section on pre-v0.13 hosts to spare users a
        // "I set this and nothing happened" trap.
        if capabilitiesStore?.capabilities.hasImageGenModel ?? false {
            SettingsSection(title: "Image Generation", icon: "photo") {
                imageGenRow
            }
        }
        // OpenRouter response caching toggle (v0.13+). Same hide-on-
        // pre-v0.13 rationale: the toggle no-ops on older Hermes hosts.
        if capabilitiesStore?.capabilities.hasOpenRouterResponseCache ?? false {
            SettingsSection(title: "OpenRouter", icon: "shippingbox") {
                openRouterResponseCacheRow
            }
        }
        // Unknown / unrecognised aux tasks present in config.yaml.
        // Shown only when at least one such key is present so the
        // typical user with a clean config never sees this section.
        if !unknownTasks.isEmpty {
            SettingsSection(title: "Other tasks in config.yaml", icon: "questionmark.folder") {
                Text("These auxiliary tasks are present in your `config.yaml` but Scarf doesn't have a typed editor for them. The most common fix is to reset their provider to `auto` so Hermes inherits the main provider. For finer edits, use **Open in Editor** at the top of Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(unknownTasks, id: \.self) { key in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                                .font(.system(.body, design: .monospaced, weight: .medium))
                            Text("Configured under `auxiliary.\(key)` in config.yaml")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        // The single most-actionable fix: reset
                        // provider to `auto`. Solves the v2.7
                        // user-reported case where removing a
                        // provider's OAuth left an aux task
                        // pointing at the now-unauthenticated
                        // provider, blocking session start with an
                        // opaque ACP -32603 internal error.
                        Button("Reset provider") {
                            viewModel.setAuxiliary(key, field: "provider", value: "auto")
                        }
                        .controlSize(.small)
                        .help(Text(verbatim: "Sets `auxiliary.\(key).provider: auto` so Hermes inherits the main provider's authentication."))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.3))
                }
            }
        }
        Color.clear.frame(height: 0)
            .onAppear {
                subscription = NousSubscriptionService(context: serverContext).loadState()
            }
            .sheet(isPresented: $showNousSignIn) {
                NousSignInSheet {
                    subscription = NousSubscriptionService(context: serverContext).loadState()
                }
            }
    }

    @ViewBuilder
    private func auxRows(for key: String) -> some View {
        let model = auxModel(for: key)
        nousGatewayToggle(for: key, currentProvider: model.provider)
        EditableTextField(label: "Provider", value: model.provider) { viewModel.setAuxiliary(key, field: "provider", value: $0) }
        EditableTextField(label: "Model", value: model.model) { viewModel.setAuxiliary(key, field: "model", value: $0) }
        EditableTextField(label: "Base URL", value: model.baseURL) { viewModel.setAuxiliary(key, field: "base_url", value: $0) }
        SecretTextField(label: "API Key", value: model.apiKey) { viewModel.setAuxiliary(key, field: "api_key", value: $0) }
        StepperRow(label: "Timeout (s)", value: model.timeout, range: 5...3600, step: 5) { viewModel.setAuxiliaryTimeout(key, value: $0) }
        if capabilitiesStore?.capabilities.hasAuxiliaryReasoningEffort ?? false {
            reasoningEffortPicker(value: model.reasoningEffort) { viewModel.setAuxiliaryReasoningEffort(key, value: $0) }
        }
    }

    /// Shared reasoning-effort picker for `auxiliary.<task>.reasoning_effort`
    /// (v0.19+) — "Default" writes an empty scalar (provider default);
    /// the other options are `AuxiliaryReasoningEffort`'s raw values,
    /// source-verified against `hermes_constants.VALID_REASONING_EFFORTS`
    /// + `parse_reasoning_effort`'s `"none"` alias.
    @ViewBuilder
    private func reasoningEffortPicker(value: String, onChange: @escaping (String) -> Void) -> some View {
        PickerRow(
            label: "Reasoning Effort",
            selection: value,
            options: [""] + AuxiliaryReasoningEffort.allCases.map(\.rawValue),
            optionLabel: { $0.isEmpty ? "Default" : $0.capitalized },
            onChange: onChange
        )
    }

    /// `auxiliary.title_generation` rows. Distinct from `auxRows` because
    /// this task carries two extra fields (`enabled`, `language`) that no
    /// other auxiliary task has.
    @ViewBuilder
    private var titleGenerationRows: some View {
        let settings = viewModel.config.auxiliary.titleGeneration
        ToggleRow(label: "Enabled", isOn: settings.enabled) { viewModel.setTitleGenerationEnabled($0) }
        EditableTextField(label: "Provider", value: settings.provider) { viewModel.setTitleGeneration(field: "provider", value: $0) }
        EditableTextField(label: "Model", value: settings.model) { viewModel.setTitleGeneration(field: "model", value: $0) }
        EditableTextField(label: "Base URL", value: settings.baseURL) { viewModel.setTitleGeneration(field: "base_url", value: $0) }
        SecretTextField(label: "API Key", value: settings.apiKey) { viewModel.setTitleGeneration(field: "api_key", value: $0) }
        StepperRow(label: "Timeout (s)", value: settings.timeout, range: 5...3600, step: 5) { viewModel.setTitleGenerationTimeout($0) }
        if capabilitiesStore?.capabilities.hasAuxiliaryReasoningEffort ?? false {
            reasoningEffortPicker(value: settings.reasoningEffort) { viewModel.setTitleGenerationReasoningEffort($0) }
        }
        if capabilitiesStore?.capabilities.hasTitleGenerationLanguage ?? false {
            EditableTextField(label: "Language", value: settings.language) { viewModel.setTitleGenerationLanguage($0) }
            Text("Force generated titles into this language (e.g. `en`, `ja`) regardless of the chat's own language. Leave blank to match the chat.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func nousGatewayToggle(for key: String, currentProvider: String) -> some View {
        let isOn = (currentProvider == "nous")
        ToggleRow(label: "Nous Portal", isOn: isOn) { wantsOn in
            // "nous" enables subscription routing; "auto" reverts to the
            // inherit-main-provider default. We never touch model/base/key
            // fields here — Hermes reuses them if the user switches back.
            viewModel.setAuxiliary(key, field: "provider", value: wantsOn ? "nous" : "auto")
        }
        if !subscription.present && !isOn {
            HStack(spacing: 8) {
                Text("Requires an active Nous Portal subscription.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Sign in first") { showNousSignIn = true }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    // MARK: - v0.13 surfaces

    /// Image-gen model picker — curated allowlist + free-form custom
    /// entry. Capability-gated by the caller; this view assumes the
    /// host honors `image_gen.model` (Hermes v0.13+).
    @ViewBuilder
    private var imageGenRow: some View {
        let value = viewModel.config.imageGenModel
        Picker("Model", selection: Binding(
            get: { value },
            set: { viewModel.setImageGenModel($0) }
        )) {
            Text("Provider default").tag("")
            Divider()
            ForEach(ModelCatalogService.imageGenModels) { model in
                Text(model.display).tag(model.modelID)
            }
            // User has set a custom value not in the curated list;
            // preserve it as a tagged option so the picker renders the
            // actual selection rather than collapsing to "Provider
            // default".
            if !value.isEmpty
                && !ModelCatalogService.imageGenModels.contains(where: { $0.modelID == value }) {
                Divider()
                Text(value + "  (custom)").tag(value)
            }
        }
        .pickerStyle(.menu)
        EditableTextField(label: "Custom model ID", value: value) { newValue in
            viewModel.setImageGenModel(newValue.trimmingCharacters(in: .whitespaces))
        }
        Text("Used for image generation calls. Leave as Provider default unless your provider documents a specific model ID for image-gen.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    /// OpenRouter response-caching toggle (Hermes v0.13+). Off by
    /// default; surfaced for users with highly repeated prompts who
    /// want OpenRouter to cache identical-prompt responses.
    @ViewBuilder
    private var openRouterResponseCacheRow: some View {
        let isOn = viewModel.config.openrouterResponseCacheEnabled
        ToggleRow(label: "Response caching", isOn: isOn) { newValue in
            viewModel.setOpenRouterResponseCache(newValue)
        }
        Text("OpenRouter caches identical prompts within a session to reduce token costs. Off by default — enable when your workload has highly repeated prompts.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    private func auxModel(for key: String) -> AuxiliaryModel {
        switch key {
        case "vision": return viewModel.config.auxiliary.vision
        case "web_extract": return viewModel.config.auxiliary.webExtract
        case "compression": return viewModel.config.auxiliary.compression
        case "session_search": return viewModel.config.auxiliary.sessionSearch
        case "skills_hub": return viewModel.config.auxiliary.skillsHub
        case "approval": return viewModel.config.auxiliary.approval
        case "mcp": return viewModel.config.auxiliary.mcp
        case "flush_memories": return viewModel.config.auxiliary.flushMemories
        case "curator": return viewModel.config.auxiliary.curator
        default: return .empty
        }
    }
}
