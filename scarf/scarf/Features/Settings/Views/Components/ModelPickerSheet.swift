import SwiftUI
import ScarfCore
import ScarfDesign

/// Two-column model browser sheet. Left column lists providers, right column
/// lists models for the selected provider. Supports filtering and a "Custom…"
/// option for free-form model IDs not in the catalog.
///
/// When the host supplies `onSelectLocal`, the provider column grows a
/// **Remote | Local** source filter: Local lists the
/// `LocalModelProvider` descriptor table (Ollama, LM Studio, vLLM,
/// llama.cpp, custom endpoint) and enumerates the models the host's
/// server actually serves via `LocalModelEnumerator`. This is a
/// picker-scoped filter, not an app-global mode.
///
/// Overlay-only providers (Nous Portal, OpenAI Codex, Qwen OAuth, …) have no
/// models.dev catalog entry, so their right column renders an overlay detail
/// view: subscription state for Nous, plus a free-form model-ID field for
/// users who know what they want. This is how the picker keeps parity with
/// `hermes model` on the CLI, which can reach these providers natively.
struct ModelPickerSheet: View {
    let initialProvider: String
    let initialModel: String
    /// Round-trip inputs for the Local tab — the current
    /// `model.base_url` / `model.api_key` / `model.api_mode` from
    /// config.yaml, so re-opening the picker on a local provider
    /// restores what the user saved. Hosts without them (preflight,
    /// where config has no model block yet) leave the defaults.
    var initialBaseURL: String = ""
    var initialAPIKey: String = ""
    var initialAPIMode: String = ""
    let onSelect: (_ modelID: String, _ providerID: String) -> Void
    /// Local-tab save path. The Remote | Local source filter is only
    /// offered when this is non-nil — hosts that can't persist the
    /// local payload (model presets, delegation) keep the classic
    /// remote-only picker, because saving `model.provider: ollama`
    /// without its `model.base_url` silently routes chats to
    /// OpenRouter (the GH #27132 failure class).
    var onSelectLocal: ((LocalModelSelection) -> Void)? = nil
    let onCancel: () -> Void

    /// Provider-column source filter — a picker-scoped filter, not an
    /// app-global mode. Remote is the untouched catalog behavior.
    private enum SourceFilter: Hashable {
        case remote
        case local
    }

    @State private var providers: [HermesProviderInfo] = []
    @State private var selectedProviderID: String = ""
    @State private var models: [HermesModelInfo] = []
    @State private var selectedModelID: String = ""
    @State private var searchText: String = ""
    /// True while the initial catalog load (or a per-provider model
    /// reload) is in flight. Drives the loading-overlay placeholder.
    /// Pre-fix this work ran synchronously inside `.onAppear` — issue
    /// #59. The catalog file is multi-MB on remote contexts; sync I/O
    /// on the MainActor froze the picker for 1–2 minutes.
    @State private var isLoadingCatalog: Bool = true

    // Custom model entry — used when the catalog doesn't have the exact model
    // the user needs (e.g., provider-prefixed IDs like "openrouter/some/model").
    @State private var customMode: Bool = false
    @State private var customModelID: String = ""
    @State private var customProviderID: String = ""

    // Overlay-provider model entry — distinct from `customMode` because the
    // provider is pinned; only the model ID is user-editable.
    @State private var overlayModelID: String = ""

    // MARK: Local-tab state

    @State private var sourceFilter: SourceFilter = .remote
    @State private var selectedLocalProviderID: String = LocalModelProvider.all.first?.providerID ?? "ollama"
    /// Pre-filled with the first descriptor's default so the Local tab
    /// never opens with a blank Ollama URL (the write plan falls back to
    /// the default anyway — this is purely so the field shows the truth).
    @State private var localBaseURL: String = LocalModelProvider.all.first?.defaultBaseURL ?? ""
    @State private var localAPIKey: String = ""
    @State private var localAPIMode: String = ""
    @State private var localModelID: String = ""
    /// Free-form model entry for local servers — same escape hatch as
    /// the Nous overlay's manual mode: enumeration is best-effort, the
    /// user must always be able to type a model the probe didn't list.
    @State private var localManualEntry: Bool = false
    /// Base URL debounced for probing — `LocalModelEnumerator.listModels`
    /// is not cancellable (detached curl, ~10 s worst case), so we must
    /// not fire a probe per keystroke. Seeded to the same value as
    /// `localBaseURL` (and re-seeded on every programmatic URL change —
    /// provider switch, round-trip restore) so the first probe after any
    /// non-typing change targets the RIGHT URL immediately instead of
    /// probing the previous URL for a 400 ms debounce window (T4 audit).
    @State private var debouncedLocalBaseURL: String = LocalModelProvider.all.first?.defaultBaseURL ?? ""
    @State private var localListing: LocalModelListing?
    @State private var localIsProbing: Bool = false
    /// Bumped by the Retry/Refresh buttons to force a re-probe with an
    /// unchanged provider+URL (`.task(id:)` only refires on key change).
    @State private var localProbeAttempt: Int = 0

    // Subscription state for the Nous Portal row / detail view. Loaded on
    // appear; stays in-memory for the life of the sheet.
    @State private var subscription: NousSubscriptionState = .absent

    /// Drives presentation of the Nous sign-in sheet. Bound to the
    /// "Sign in to Nous Portal" button in the subscription summary.
    @State private var showNousSignIn: Bool = false

    /// Cached + freshly-fetched Nous model list for the picker's
    /// nous-overlay branch. Populated on appear (cache-first) and
    /// refreshed when the user signs in or hits the Refresh button.
    @State private var nousModels: [NousModel] = []
    @State private var nousFetchedAt: Date?
    @State private var nousRefreshError: String?
    @State private var nousIsRefreshing: Bool = false
    /// When true, render the Nous detail with the original free-form
    /// TextField + manual hint instead of the model list. Used when
    /// the user explicitly wants to type a model not in the catalog —
    /// the API list is comprehensive but not infallible, so always
    /// keep the escape hatch reachable.
    @State private var nousManualEntry: Bool = false

    /// Validation failure surfaced on Select when the typed / selected
    /// model isn't in the chosen provider's catalog. Pass-1 M7 #5
    /// cross-platform fix — previously Scarf let you save any string
    /// and the failure only appeared hours later at runtime.
    @State private var validationIssue: ModelValidationIssue?

    @Environment(\.serverContext) private var serverContext
    private var catalog: ModelCatalogService { ModelCatalogService(context: serverContext) }
    private var subscriptionService: NousSubscriptionService { NousSubscriptionService(context: serverContext) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if customMode {
                customEntry
            } else {
                HSplitView {
                    providerColumn.frame(minWidth: 220, idealWidth: 240)
                    modelColumn.frame(minWidth: 340)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .overlay {
            if isLoadingCatalog {
                ProgressView("Loading providers…")
                    .progressViewStyle(.circular)
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            // Off-MainActor read of the multi-megabyte models.dev cache
            // (via SSHTransport on remote contexts). Pre-fix this ran
            // sync inside `.onAppear` and froze the picker for 1–2
            // minutes on remote contexts (issue #59).
            isLoadingCatalog = true
            providers = await catalog.loadProvidersAsync()
            selectedProviderID = initialProvider.isEmpty ? (providers.first?.providerID ?? "") : initialProvider
            selectedModelID = initialModel
            overlayModelID = initialModel
            // Round-trip: when the saved provider is one of the local
            // descriptors (or a runtime spelling alias like
            // `llama.cpp`), open straight onto the Local tab with the
            // saved base URL / key / mode restored.
            if onSelectLocal != nil,
               let descriptor = LocalModelProvider.descriptor(for: initialProvider) {
                sourceFilter = .local
                selectedLocalProviderID = descriptor.providerID
                localModelID = initialModel
                localBaseURL = initialBaseURL.isEmpty
                    ? (descriptor.defaultBaseURL ?? "")
                    : initialBaseURL
                // Programmatic URL change — skip the typing debounce so
                // the restore probes the SAVED URL immediately, not the
                // descriptor default for a 400 ms window.
                debouncedLocalBaseURL = localBaseURL
                localAPIKey = initialAPIKey
                // Normalize like the runtime (_parse_api_mode strips +
                // lowercases); values outside the picker's four modes
                // (e.g. a hand-typed codex_app_server) fall back to
                // Auto-detect rather than leaving the Picker tag-less.
                let mode = initialAPIMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                localAPIMode = LocalModelProvider.pickerAPIModes.contains(mode) ? mode : ""
            }
            // subscriptionService.loadState() reads auth.json — tiny
            // on local but still SSH-backed on remote, so route it
            // through a detached task too. The result is a small
            // value type; safe to assign back onto MainActor.
            let svc = subscriptionService
            subscription = await Task.detached { svc.loadState() }.value
            await loadModelsForSelectionAsync()
            isLoadingCatalog = false
        }
        .sheet(isPresented: $showNousSignIn) {
            NousSignInSheet {
                // Refresh subscription immediately so the right-column
                // status row flips to "active" without waiting for the
                // picker to be re-opened.
                subscription = subscriptionService.loadState()
                // Sign-in unlocked the bearer token — kick a fresh
                // model-list fetch so the picker populates without the
                // user needing to hit Refresh manually.
                Task { await refreshNousModels(forceRefresh: true) }
            }
        }
        .alert(item: $validationIssue) { issue in
            Alert(
                title: Text("Model not available"),
                message: Text(validationMessage(for: issue)),
                primaryButton: .default(Text("Pick from catalog")) {
                    validationIssue = nil
                    customMode = false
                },
                secondaryButton: .cancel(Text("Edit"))
            )
        }
    }

    private func validationMessage(for issue: ModelValidationIssue) -> String {
        var msg = "\(issue.modelID) isn't in \(issue.providerName)'s catalog."
        if !issue.suggestions.isEmpty {
            msg += " Did you mean one of:\n• " + issue.suggestions.joined(separator: "\n• ")
        } else {
            msg += " Pick one from the catalog or double-check the spelling."
        }
        return msg
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
            Text("Select Model")
                .scarfStyle(.headline)
            Spacer()
            if !customMode {
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            Button(customMode ? "Back to Catalog" : "Custom…") {
                customMode.toggle()
                if customMode {
                    customModelID = initialModel
                    customProviderID = initialProvider
                }
            }
            .controlSize(.small)
        }
        .padding()
    }

    private var providerColumn: some View {
        VStack(spacing: 0) {
            if onSelectLocal != nil {
                Picker("Source", selection: $sourceFilter) {
                    Text("Remote").tag(SourceFilter.remote)
                    Text("Local").tag(SourceFilter.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            if sourceFilter == .local {
                localProviderList
            } else {
                remoteProviderList
            }
        }
    }

    private var remoteProviderList: some View {
        List(selection: Binding(
            get: { selectedProviderID },
            set: { newValue in
                selectedProviderID = newValue
                Task { await loadModelsForSelectionAsync() }
            }
        )) {
            ForEach(filteredProviders) { provider in
                providerRow(provider)
                    .tag(provider.providerID)
            }
        }
        .listStyle(.inset)
    }

    /// Left column for the Local filter — the fixed descriptor table
    /// (Ollama, LM Studio, vLLM, llama.cpp, custom endpoint), rendered
    /// in the table's own most-common-first order.
    private var localProviderList: some View {
        List(selection: Binding(
            get: { selectedLocalProviderID },
            set: { selectLocalProvider($0) }
        )) {
            ForEach(filteredLocalProviders) { provider in
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                    Text(provider.blurb)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .tag(provider.providerID)
            }
        }
        .listStyle(.inset)
    }

    /// Selecting a different local provider resets the endpoint fields
    /// to that descriptor's defaults — deliberately NOT `.onChange`, so
    /// the round-trip restore in `.task` can seed saved values without
    /// this reset clobbering them.
    private func selectLocalProvider(_ id: String) {
        guard id != selectedLocalProviderID else { return }
        selectedLocalProviderID = id
        let descriptor = LocalModelProvider.descriptor(for: id)
        localBaseURL = descriptor?.defaultBaseURL ?? ""
        // Programmatic URL change — skip the typing debounce so the
        // probe key never pairs the new provider with the old URL.
        debouncedLocalBaseURL = localBaseURL
        localAPIKey = ""
        localAPIMode = ""
        localModelID = ""
        localManualEntry = false
        localListing = nil
    }

    @ViewBuilder
    private func providerRow(_ provider: HermesProviderInfo) -> some View {
        HStack(spacing: 6) {
            Text(provider.providerName)
            if provider.subscriptionGated {
                capsuleTag("Subscription", tint: .accentColor)
            }
            Spacer()
            if !provider.isOverlay {
                Text("\(provider.modelCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modelColumn: some View {
        if sourceFilter == .local {
            if let descriptor = selectedLocalDescriptor {
                localProviderDetail(descriptor)
            } else {
                ContentUnavailableView("Pick a server", systemImage: "desktopcomputer", description: Text("Choose a local server type on the left."))
            }
        } else if let selected = providers.first(where: { $0.providerID == selectedProviderID }) {
            if selected.providerID == "nous" {
                nousOverlayDetail(selected)
            } else if selected.isOverlay {
                overlayProviderDetail(selected)
            } else {
                cachedModelList
            }
        } else {
            cachedModelList
        }
    }

    private var cachedModelList: some View {
        List(selection: $selectedModelID) {
            ForEach(filteredModels) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.modelName)
                            .font(.system(.body, design: .default, weight: .medium))
                        Spacer()
                        if let ctx = model.contextDisplay {
                            Text("\(ctx) ctx")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(model.modelID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        if let cost = model.costDisplay {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(cost)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if model.toolCall {
                            capsuleTag("tools")
                        }
                        if model.reasoning {
                            capsuleTag("reasoning")
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(model.modelID)
            }
        }
        .listStyle(.inset)
        .overlay {
            if filteredModels.isEmpty {
                ContentUnavailableView("No Models", systemImage: "cpu", description: Text("This provider has no catalogued models."))
            }
        }
    }

    /// Right-column detail for Nous Portal — same overlay shape as
    /// `overlayProviderDetail` but with a live model list fetched from
    /// Nous's OpenAI-compatible `/v1/models` endpoint. The list is
    /// cache-first so opening the sheet feels instant; refresh runs
    /// in the background. Falls back to a hard-coded short list when
    /// the user has no token AND no cache (offline first-run on a
    /// fresh remote install). The "Custom…" button below the list
    /// flips to the original free-form TextField — Nous occasionally
    /// adds a model before our cache hits 24h, and we don't want
    /// users locked out of the latest releases.
    @ViewBuilder
    private func nousOverlayDetail(_ provider: HermesProviderInfo) -> some View {
        let overlay = catalog.overlayMetadata(for: provider.providerID)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(provider.providerName).font(.title3.bold())
                    if provider.subscriptionGated {
                        capsuleTag("Subscription", tint: .accentColor)
                    }
                }
                if provider.subscriptionGated {
                    subscriptionSummary(provider: provider, overlay: overlay)
                }
                Divider()
                if nousManualEntry {
                    nousManualEntryBlock(provider: provider)
                } else {
                    nousModelListBlock
                }
                if let docURL = overlay?.docURL, let url = URL(string: docURL) {
                    Link(destination: url) {
                        Label("Setup documentation", systemImage: "book")
                            .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var nousModelListBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if nousIsRefreshing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing…").font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Button {
                        Task { await refreshNousModels(forceRefresh: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(nousFetchedAtTooltip)
                }
                Button("Custom…") { nousManualEntry = true }
                    .controlSize(.small)
            }
            if let err = nousRefreshError, !nousIsRefreshing {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List(selection: $overlayModelID) {
                ForEach(filteredNousModels) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.id)
                            .font(.system(.body, design: .monospaced))
                        if let owner = model.owned_by, !owner.isEmpty {
                            Text(owner)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(model.id)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            .overlay {
                if filteredNousModels.isEmpty && !nousIsRefreshing {
                    if nousModels.isEmpty {
                        ContentUnavailableView(
                            "No models loaded",
                            systemImage: "cpu",
                            description: Text("Sign in to Nous Portal to load the catalog, or enter a model ID manually.")
                        )
                    } else {
                        // Models loaded but the search filtered them all
                        // out. Different message so the user knows the
                        // catalog is fine, just their query didn't match.
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "magnifyingglass",
                            description: Text("No models match \"\(searchText)\".")
                        )
                    }
                }
            }
            if nousFetchedAt == nil && !nousModels.isEmpty {
                Text("Showing built-in fallback list — couldn't reach Nous to refresh.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("Leave blank in config to let Hermes pick the default Nous model. Picking one above writes it explicitly.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func nousManualEntryBlock(provider: HermesProviderInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Model ID").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use list") { nousManualEntry = false }
                    .controlSize(.small)
            }
            TextField(modelIDPlaceholder(for: provider), text: $overlayModelID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Text("Type a model ID exactly as Nous expects it. Leave blank to use Hermes's default.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private static let fetchedAtFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var nousFetchedAtTooltip: String {
        guard let date = nousFetchedAt else {
            return "Fetch the latest model list from Nous."
        }
        return "Last refreshed \(Self.fetchedAtFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    /// Right-column detail for overlay-only providers (Nous Portal, OpenAI
    /// Codex, Qwen OAuth, …). models.dev has no catalog for them, so the user
    /// either trusts Hermes's default (subscription providers) or types a
    /// model ID they know is valid for the provider's API.
    @ViewBuilder
    private func overlayProviderDetail(_ provider: HermesProviderInfo) -> some View {
        let overlay = catalog.overlayMetadata(for: provider.providerID)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(provider.providerName).font(.title3.bold())
                    if provider.subscriptionGated {
                        capsuleTag("Subscription", tint: .accentColor)
                    }
                }
                if provider.subscriptionGated {
                    subscriptionSummary(provider: provider, overlay: overlay)
                } else {
                    Text(overlayInstruction(for: overlay?.authType))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model ID").font(.caption).foregroundStyle(.secondary)
                    TextField(modelIDPlaceholder(for: provider), text: $overlayModelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    if provider.subscriptionGated {
                        Text("Leave blank to use Hermes's default Nous model.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let docURL = overlay?.docURL, let url = URL(string: docURL) {
                    Link(destination: url) {
                        Label("Setup documentation", systemImage: "book")
                            .font(.caption)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func subscriptionSummary(provider: HermesProviderInfo, overlay: HermesProviderOverlay?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paid Nous Portal subscribers route web search, image generation, TTS, and browser automation through their subscription — no separate API keys needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: subscription.subscribed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(subscription.subscribed ? Color.green : Color.secondary)
                if subscription.subscribed {
                    Text("Subscription active — active provider is Nous.")
                } else if subscription.present {
                    Text("Signed in to Nous, but another provider is active.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not signed in yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if !subscription.subscribed {
                Button {
                    showNousSignIn = true
                } label: {
                    Label("Sign in to Nous Portal", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(ScarfPrimaryButton())
                .controlSize(.regular)
            }
        }
    }

    private func overlayInstruction(for authType: HermesProviderOverlay.AuthType?) -> String {
        switch authType {
        case .oauthExternal:
            return "Sign in through the provider's OAuth flow — run `hermes auth` from a terminal, then pick the provider to complete sign-in. Back here, set the model ID you want to use."
        case .externalProcess:
            return "Uses an external process (e.g. a local agent bridge). Run `hermes auth` from a terminal to complete the link, then set the model ID you want to use."
        case .oauthDeviceCode:
            return "Sign in via device-code flow — run `hermes auth` from a terminal and follow the printed URL."
        case .virtual:
            return "No credentials needed — this is a local virtual provider. Enter the preset name you want to use (e.g. `default`)."
        default:
            return "This provider isn't in the models.dev catalog. Enter the model ID you want to use — Hermes will pass it through to the provider verbatim."
        }
    }

    private func modelIDPlaceholder(for provider: HermesProviderInfo) -> String {
        switch provider.providerID {
        case "nous":          return "e.g. hermes-3"
        case "openai-codex":  return "e.g. gpt-5-codex"
        case "qwen-oauth":    return "e.g. qwen3-coder-plus"
        default:              return "e.g. model-name"
        }
    }

    // MARK: - Local provider detail

    private var selectedLocalDescriptor: LocalModelProvider? {
        LocalModelProvider.descriptor(for: selectedLocalProviderID)
    }

    /// The base URL the probe (and the save) effectively uses — the
    /// field's value, falling back to the descriptor's default.
    private func effectiveLocalBaseURL(_ descriptor: LocalModelProvider) -> String {
        let trimmed = localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (descriptor.defaultBaseURL ?? "") : trimmed
    }

    /// Right-column detail for a local provider: endpoint fields on top,
    /// live-enumerated model list below — plus a free-form entry mode as
    /// the always-reachable escape hatch (Nous-overlay precedent).
    @ViewBuilder
    private func localProviderDetail(_ descriptor: LocalModelProvider) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(descriptor.displayName).font(.title3.bold())
                Text(descriptor.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(descriptor.credentialInstruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                localEndpointFields(descriptor)

                Divider()

                localModelsBlock(descriptor)

                Spacer(minLength: 0)
            }
            .padding()
        }
        // Debounce typing before the probe key sees the URL —
        // `LocalModelEnumerator.listModels` is not cancellable (detached
        // curl, ~10 s worst case), so per-keystroke probes would stack.
        .task(id: localBaseURL) {
            if debouncedLocalBaseURL != localBaseURL {
                // Unconditional pause: each keystroke re-runs this task
                // (cancelling the sleeping predecessor), so the probe key
                // only ever sees a URL the user stopped typing.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                debouncedLocalBaseURL = localBaseURL
            }
        }
        .task(id: localProbeKey) {
            await probeLocalModels()
        }
    }

    private var localProbeKey: String {
        "\(selectedLocalProviderID)|\(debouncedLocalBaseURL)|\(localProbeAttempt)"
    }

    private func probeLocalModels() async {
        guard let descriptor = selectedLocalDescriptor else { return }
        guard descriptor.enumerationHint != .none else {
            localListing = .notEnumerable
            return
        }
        let key = localProbeKey
        localIsProbing = true
        localListing = nil
        let listing = await LocalModelEnumerator.listModels(
            for: descriptor,
            baseURL: debouncedLocalBaseURL,
            context: serverContext
        )
        // The probe itself runs to completion even after this task is
        // cancelled (sheet dismissed, provider switched) — never let a
        // stale result overwrite a newer selection's state.
        guard !Task.isCancelled, key == localProbeKey else { return }
        localIsProbing = false
        localListing = listing
    }

    @ViewBuilder
    private func localEndpointFields(_ descriptor: LocalModelProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Base URL").font(.caption).foregroundStyle(.secondary)
                if descriptor.baseURLRequired {
                    // Same required-field affordance as ModelPresetEditSheet.
                    Text("*").font(.caption).foregroundStyle(ScarfColor.danger)
                }
            }
            TextField(descriptor.baseURLPlaceholder, text: $localBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
            if descriptor.baseURLRequired,
               descriptor.defaultBaseURL == nil,
               localBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Required — this server has no default endpoint.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if descriptor.providerID == "ollama" {
                Text("Always saved to config — without it, chats silently route to OpenRouter.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        if descriptor.supportsAPIKey {
            VStack(alignment: .leading, spacing: 4) {
                Text("API key (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("Leave blank for local servers", text: $localAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
        }

        if descriptor.supportsAPIMode {
            VStack(alignment: .leading, spacing: 4) {
                Text("API mode").font(.caption).foregroundStyle(.secondary)
                Picker("API mode", selection: $localAPIMode) {
                    Text("Auto-detect").tag("")
                    ForEach(LocalModelProvider.pickerAPIModes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func localModelsBlock(_ descriptor: LocalModelProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if localIsProbing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…").font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Button {
                        localProbeAttempt += 1
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Probe the server again for its installed models.")
                }
                Button(localManualEntry ? "Use list" : "Enter manually") {
                    localManualEntry.toggle()
                }
                .controlSize(.small)
            }
            if localManualEntry {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(localModelPlaceholder(for: descriptor), text: $localModelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Text("Type the model ID exactly as the server reports it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                localModelList(descriptor)
            }
            if descriptor.allowsEmptyModelWhenLoopback {
                Text("On a loopback URL you can leave the model empty — Hermes auto-detects the single loaded model.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func localModelPlaceholder(for descriptor: LocalModelProvider) -> String {
        switch descriptor.providerID {
        case "ollama":   return "e.g. llama3:8b"
        case "lmstudio": return "e.g. qwen2.5-coder-14b"
        default:         return "e.g. model-name"
        }
    }

    @ViewBuilder
    private func localModelList(_ descriptor: LocalModelProvider) -> some View {
        List(selection: $localModelID) {
            ForEach(filteredLocalModels) { model in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(.body, design: .monospaced))
                    if let detail = model.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
                .tag(model.modelID)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 200)
        .overlay {
            if localIsProbing && filteredLocalModels.isEmpty {
                ProgressView("Checking \(descriptor.displayName)…")
                    .controlSize(.small)
            } else if filteredLocalModels.isEmpty {
                localEmptyState(descriptor)
            }
        }
    }

    /// Outcome-specific empty states — a down daemon, an empty library,
    /// and a wrong endpoint each get their own copy instead of one
    /// generic "no models".
    @ViewBuilder
    private func localEmptyState(_ descriptor: LocalModelProvider) -> some View {
        switch localListing {
        case .unreachable:
            ContentUnavailableView {
                Label("Can't reach \(descriptor.displayName)", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(unreachableDescription(descriptor))
            } actions: {
                Button("Retry") { localProbeAttempt += 1 }
            }
        case .reachableEmpty:
            ContentUnavailableView(
                "No models installed",
                systemImage: "cpu",
                description: Text(reachableEmptyDescription(descriptor))
            )
        case .parseFailure:
            ContentUnavailableView(
                "Unexpected response",
                systemImage: "questionmark.circle",
                description: Text("The endpoint answered, but not with a model list. Check that the base URL points at \(descriptor.displayName)'s API, or enter the model ID manually.")
            )
        case .invalidBaseURL:
            ContentUnavailableView(
                "Enter a base URL",
                systemImage: "link",
                description: Text("Use the form http://host:port/v1 — e.g. \(descriptor.baseURLPlaceholder).")
            )
        case .notEnumerable:
            ContentUnavailableView(
                "No listing for this server",
                systemImage: "keyboard",
                description: Text("Enter the model ID manually.")
            )
        case .models:
            // Loaded fine — the search filtered everything out.
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No models match \"\(searchText)\".")
            )
        case nil:
            EmptyView()
        }
    }

    /// Softened on purpose: the probe's `curl -f` maps an HTTP error
    /// (e.g. 404 from probing a wrong endpoint) to the same outcome as
    /// a down daemon, so never assert "isn't running".
    private func unreachableDescription(_ descriptor: LocalModelProvider) -> String {
        let url = effectiveLocalBaseURL(descriptor)
        let target = url.isEmpty ? descriptor.baseURLPlaceholder : url
        if serverContext.isRemote {
            return "Couldn't reach \(descriptor.displayName) at \(target) on \(serverContext.displayName) — is it running there? The URL is probed from that server, not this Mac."
        }
        return "Couldn't reach \(descriptor.displayName) at \(target) — is it running?"
    }

    private func reachableEmptyDescription(_ descriptor: LocalModelProvider) -> String {
        if descriptor.providerID == "ollama" {
            return "The server is running but has no models. Run `ollama pull <model>`, then refresh."
        }
        return "The server is running but reports no models loaded. Load one and refresh, or enter its ID manually."
    }

    private var filteredLocalModels: [LocalModelInfo] {
        guard case .models(let models) = localListing else { return [] }
        guard !searchText.isEmpty else { return models }
        let q = searchText.lowercased()
        return models.filter { $0.modelID.lowercased().contains(q) }
    }

    private var filteredLocalProviders: [LocalModelProvider] {
        guard !searchText.isEmpty else { return LocalModelProvider.all }
        let q = searchText.lowercased()
        return LocalModelProvider.all.filter {
            $0.displayName.lowercased().contains(q) || $0.providerID.contains(q)
        }
    }

    /// Loopback gate for the custom endpoint's empty-model auto-detect.
    /// Delegates to the descriptor table's reader-verified check — the
    /// runtime only auto-detects when the base URL contains
    /// `localhost`/`127.0.0.1` literally (runtime_provider.py:209), so
    /// `::1` or `127.0.0.2` must NOT unlock the empty-model save (T4
    /// audit: they'd produce a config Hermes runs with no model at all).
    private func isLoopbackURL(_ raw: String) -> Bool {
        LocalModelProvider.hermesAutoDetectsEmptyModel(baseURL: raw)
    }

    private var customEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use a model not in the catalog. Hermes accepts any string the provider recognizes, including provider-prefixed forms like \"openrouter/anthropic/claude-opus-4.6\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. openai/gpt-4o", text: $customModelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. openai", text: $customProviderID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("Leave blank to infer from the model ID's prefix (\"openai/...\" → openai).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if customMode {
                Text(customProviderPreview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let preview = selectedPreview {
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onCancel() }
            Button("Select") { submitSelection() }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(!canSubmit)
        }
        .padding()
    }

    // MARK: - Helpers

    private var filteredProviders: [HermesProviderInfo] {
        guard !searchText.isEmpty else { return providers }
        let q = searchText.lowercased()
        return providers.filter {
            $0.providerName.lowercased().contains(q) || $0.providerID.lowercased().contains(q)
        }
    }

    private var filteredModels: [HermesModelInfo] {
        guard !searchText.isEmpty else { return models }
        let q = searchText.lowercased()
        return models.filter {
            $0.modelName.lowercased().contains(q) || $0.modelID.lowercased().contains(q)
        }
    }

    /// Same shape as `filteredModels` but for the Nous overlay path
    /// (`nousModels` is `[NousModel]`, not `[HermesModelInfo]`).
    /// Nous returned 402 models in the user's capture; without a
    /// filter the picker is a flat unsearchable list. Reuses the
    /// same `searchText` field so the user types once and both
    /// paths respond.
    private var filteredNousModels: [NousModel] {
        guard !searchText.isEmpty else { return nousModels }
        let q = searchText.lowercased()
        return nousModels.filter {
            $0.id.lowercased().contains(q) || ($0.owned_by ?? "").lowercased().contains(q)
        }
    }

    private var isSelectedProviderOverlay: Bool {
        providers.first(where: { $0.providerID == selectedProviderID })?.isOverlay ?? false
    }

    private var isSelectedProviderSubscriptionGated: Bool {
        providers.first(where: { $0.providerID == selectedProviderID })?.subscriptionGated ?? false
    }

    private var canSubmit: Bool {
        if customMode {
            return !customModelID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if sourceFilter == .local {
            guard let descriptor = selectedLocalDescriptor, onSelectLocal != nil else { return false }
            let base = effectiveLocalBaseURL(descriptor)
            if descriptor.baseURLRequired && base.isEmpty { return false }
            guard LocalModelProvider.isValidAPIMode(localAPIMode) else { return false }
            let model = localModelID.trimmingCharacters(in: .whitespaces)
            if model.isEmpty {
                // Only the custom endpoint on a loopback URL may save an
                // empty model (Hermes single-model auto-detect).
                return descriptor.allowsEmptyModelWhenLoopback && isLoopbackURL(base)
            }
            return true
        }
        if isSelectedProviderOverlay {
            // Subscription-gated providers can submit with an empty model ID
            // (Hermes picks its default). Other overlays require a model ID.
            if isSelectedProviderSubscriptionGated { return true }
            return !overlayModelID.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !selectedModelID.isEmpty
    }

    private var selectedPreview: String? {
        if sourceFilter == .local {
            guard let descriptor = selectedLocalDescriptor else { return nil }
            let model = localModelID.trimmingCharacters(in: .whitespaces)
            if model.isEmpty {
                // Only the custom endpoint may save without a model
                // (loopback auto-detect); everything else needs a pick.
                return descriptor.allowsEmptyModelWhenLoopback
                    ? "\(descriptor.providerID) / (auto-detect)"
                    : "\(descriptor.providerID) / (pick a model)"
            }
            return "\(descriptor.providerID) / \(model)"
        }
        if isSelectedProviderOverlay {
            let trimmed = overlayModelID.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return selectedProviderID.isEmpty ? nil : "\(selectedProviderID) / (default)"
            }
            return "\(selectedProviderID) / \(trimmed)"
        }
        guard !selectedModelID.isEmpty, !selectedProviderID.isEmpty else { return nil }
        return "\(selectedProviderID) / \(selectedModelID)"
    }

    private var customProviderPreview: String {
        let resolved = resolvedCustomProvider()
        return resolved.isEmpty ? "Provider will not be changed" : "Provider → \(resolved)"
    }

    /// Async variant of the per-provider catalog read. Pre-fix this
    /// was synchronous on the MainActor and froze the picker every
    /// time the user clicked a different provider — same root cause
    /// as the open-sheet freeze (issue #59). Routes through
    /// `loadModelsAsync(for:)` which dispatches the SSHTransport
    /// file read off the main thread.
    private func loadModelsForSelectionAsync() async {
        guard !selectedProviderID.isEmpty else {
            models = []
            return
        }
        models = await catalog.loadModelsAsync(for: selectedProviderID)
        // If the current selection is not in the new list, don't try to keep
        // stale highlight state — clear unless the user originally had this model.
        if !models.contains(where: { $0.modelID == selectedModelID }) {
            selectedModelID = models.first?.modelID ?? ""
        }
        // Cache-first kick for the Nous catalog. Renders from cache
        // immediately, fires a background refresh if stale or empty.
        if selectedProviderID == "nous" {
            Task { await refreshNousModels(forceRefresh: false) }
        }
    }

    /// Cache-first load of the Nous model list. Updates the four
    /// `@State` vars the detail view reads. Force-refresh skips the
    /// TTL check so the user-tapped Refresh button always hits the
    /// network — the cache write keeps the next sheet-open instant.
    private func refreshNousModels(forceRefresh: Bool) async {
        let service = NousModelCatalogService(context: serverContext)
        // PRE-FIX (v2.7): this used to call `service.readCache()`
        // synchronously here for instant first-paint, then call
        // `service.loadModels(...)` which calls `readCache()` AGAIN
        // internally — paying the SSH round-trip TWICE per picker
        // open. On a remote with a corrupt or oversized cache file,
        // the duplicated reads stacked two 60-second timeouts for a
        // 120-second picker stall. ScarfMon perf capture confirmed
        // the duplication.
        //
        // loadModels() already serves cache-first on its happy path
        // (returns `.cache(...)` when fresh), so the inline readCache
        // here is redundant. Drop it; trust loadModels' built-in
        // cache-first behavior. One readCache call per picker open.
        nousIsRefreshing = true
        let result = await service.loadModels(forceRefresh: forceRefresh)
        nousIsRefreshing = false
        switch result {
        case .fresh(let models, let fetchedAt):
            nousModels = models
            nousFetchedAt = fetchedAt
            nousRefreshError = nil
        case .cache(let models, let fetchedAt, let refreshError):
            nousModels = models
            nousFetchedAt = fetchedAt
            nousRefreshError = refreshError
        case .fallback(let models, let reason):
            nousModels = models
            nousFetchedAt = nil
            nousRefreshError = reason
        }
        // Pre-fill `overlayModelID` with the user's previously chosen
        // model when it's in the freshly-loaded list — otherwise the
        // selection state highlights nothing on first paint.
        if !overlayModelID.isEmpty,
           !nousModels.contains(where: { $0.id == overlayModelID }) {
            // Leave overlayModelID alone — it's a user-typed value
            // that may legitimately not be in the catalog.
        }
    }

    /// When the user enters a custom model ID without explicitly naming a
    /// provider, infer from a `provider/model` prefix if present. Otherwise
    /// fall back to whatever is currently selected (we never blank out the
    /// existing provider silently).
    private func resolvedCustomProvider() -> String {
        let explicit = customProviderID.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty { return explicit }
        if let slash = customModelID.firstIndex(of: "/") {
            return String(customModelID[customModelID.startIndex..<slash])
        }
        return ""
    }

    private func submitSelection() {
        // Local tab: hand the host the full LocalModelSelection payload —
        // the host writes it through LocalModelConfigPlan (provider +
        // model + base_url [+ api_key/api_mode], with the
        // clear-on-switch rule). No models.dev validation: local
        // catalogs aren't in models.dev.
        if !customMode, sourceFilter == .local {
            guard let descriptor = selectedLocalDescriptor, let onSelectLocal else { return }
            let base = localBaseURL.trimmingCharacters(in: .whitespaces)
            let key = localAPIKey.trimmingCharacters(in: .whitespaces)
            let mode = localAPIMode.trimmingCharacters(in: .whitespaces).lowercased()
            onSelectLocal(LocalModelSelection(
                providerID: descriptor.providerID,
                modelID: localModelID.trimmingCharacters(in: .whitespaces),
                baseURL: base.isEmpty ? nil : base,
                apiKey: (descriptor.supportsAPIKey && !key.isEmpty) ? key : nil,
                apiMode: (descriptor.supportsAPIMode && !mode.isEmpty) ? mode : nil
            ))
            return
        }

        let (model, provider): (String, String)
        if customMode {
            model = customModelID.trimmingCharacters(in: .whitespaces)
            provider = resolvedCustomProvider()
        } else if isSelectedProviderOverlay {
            model = overlayModelID.trimmingCharacters(in: .whitespaces)
            provider = selectedProviderID
        } else {
            model = selectedModelID
            provider = selectedProviderID
        }

        // Block unknown models before they land in config.yaml.
        // Overlay-only providers short-circuit to .valid inside the
        // validator because their catalogs aren't in models.dev.
        switch catalog.validateModel(model, for: provider) {
        case .valid, .unknownProvider:
            onSelect(model, provider)
        case .invalid(let providerName, let suggestions):
            validationIssue = ModelValidationIssue(
                modelID: model,
                providerName: providerName,
                suggestions: suggestions
            )
        }
    }

    private func capsuleTag(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint == .secondary ? AnyShapeStyle(.quaternary) : AnyShapeStyle(tint.opacity(0.15)))
            .clipShape(Capsule())
    }
}

/// Carrier for the catalog-validation alert. Identifiable so SwiftUI's
/// `.alert(item:)` can key off each unique issue.
private struct ModelValidationIssue: Identifiable {
    let id = UUID()
    let modelID: String
    let providerName: String
    let suggestions: [String]
}
