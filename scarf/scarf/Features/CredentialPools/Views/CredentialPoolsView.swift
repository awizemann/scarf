import SwiftUI

struct CredentialPoolsView: View {
    @State private var viewModel: CredentialPoolsViewModel
    @State private var showAddSheet = false
    @State private var pendingRemove: HermesCredential?

    init(context: ServerContext) {
        _viewModel = State(initialValue: CredentialPoolsViewModel(context: context))
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                safetyNotice
                if viewModel.isLoading {
                    ProgressView().padding()
                } else if viewModel.pools.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.pools) { pool in
                        poolSection(pool)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Credential Pools")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading credentials…",
            isEmpty: viewModel.pools.isEmpty
        )
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showAddSheet) {
            AddCredentialSheet(viewModel: viewModel) {
                showAddSheet = false
            }
        }
        .confirmationDialog(
            pendingRemove.map { "Remove credential for \($0.provider)?" } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let target = pendingRemove {
                    viewModel.removeCredential(provider: target.provider, index: target.index)
                }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("This removes the credential from hermes. The upstream provider key is not revoked.")
        }
    }

    private var header: some View {
        HStack {
            if let msg = viewModel.message {
                Label(msg, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Label("Add Credential", systemImage: "plus")
            }
            .controlSize(.small)
            Button("Reload") { viewModel.load() }
                .controlSize(.small)
        }
    }

    private var safetyNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("API keys are never displayed in full. Scarf only shows the last 4 characters for identification. Full key values are stored by hermes in ~/.hermes/auth.json.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No credential pools configured")
                .foregroundStyle(.secondary)
            Text("Add rotation credentials so hermes can failover between keys when one hits rate limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private func poolSection(_ pool: HermesCredentialPool) -> some View {
        SettingsSection(title: LocalizedStringKey(pool.provider), icon: "key.horizontal") {
            PickerRow(label: "Rotation", selection: pool.strategy, options: viewModel.strategyOptions) { strategy in
                viewModel.setStrategy(strategy, for: pool.provider)
            }
            ForEach(pool.credentials) { cred in
                HStack(spacing: 12) {
                    Image(systemName: cred.authType == "oauth" ? "person.badge.key" : "key.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("#\(cred.index + 1)")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                            if !cred.label.isEmpty {
                                Text(cred.label).font(.caption)
                            }
                            if !cred.authType.isEmpty {
                                Text(cred.authType)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                            if !cred.lastStatus.isEmpty {
                                Text(cred.lastStatus)
                                    .font(.caption2)
                                    .foregroundStyle(statusColor(cred.lastStatus))
                            }
                            expiryBadge(cred)
                        }
                        HStack(spacing: 8) {
                            Text(cred.tokenTail.isEmpty ? "—" : cred.tokenTail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if !cred.source.isEmpty {
                                Text(cred.source)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if cred.requestCount > 0 {
                                Text("\(cred.requestCount) req")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let rotated = cred.agentKeyObtainedAt {
                                Text("agent key · \(Self.relativeAge(rotated))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { pendingRemove = cred }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Reset Cooldowns") { viewModel.resetProvider(pool.provider) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok", "active": return .green
        case "cooldown": return .orange
        case "exhausted": return .red
        default: return .secondary
        }
    }

    /// Red "expired" / orange "expires in Nd" pill shown inline with the
    /// credential's auth-type chip. Hidden when the credential has no
    /// expiry or is more than 7 days out — no point pulling attention to a
    /// token the user doesn't need to think about yet.
    @ViewBuilder
    private func expiryBadge(_ cred: HermesCredential) -> some View {
        if let badge = cred.expiryBadge() {
            switch badge {
            case .expired:
                Text("expired")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red)
                    .clipShape(Capsule())
            case .expiringSoon(let days):
                Text("expires in \(days)d")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    /// "2h ago" / "3d ago" / "just now". Kept terse for the one-line
    /// credential row. `RelativeDateTimeFormatter` isn't used because its
    /// output ("2 hours ago") is too long for the slot.
    private static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// Two-step sheet for adding a credential:
/// 1. Provider picker (populated from the models catalog, falls back to free text)
///    + type selector (API Key vs OAuth) + optional label
/// 2. Either an immediate save (API key) or an embedded terminal running the
///    OAuth flow so the user can paste the authorization code back.
private struct AddCredentialSheet: View {
    @Bindable var viewModel: CredentialPoolsViewModel
    let onDismiss: () -> Void

    enum AuthType: String, CaseIterable, Identifiable {
        case apiKey = "API Key"
        case oauth = "OAuth"
        var id: String { rawValue }

        var displayName: LocalizedStringResource {
            switch self {
            case .apiKey: return "API Key"
            case .oauth: return "OAuth"
            }
        }
    }

    @State private var providerID: String = ""
    @State private var authType: AuthType = .apiKey
    @State private var apiKey: String = ""
    @State private var label: String = ""
    @State private var providers: [HermesProviderInfo] = []
    @State private var oauthStarted: Bool = false
    @State private var authCode: String = ""
    /// Drives presentation of the dedicated Nous sign-in sheet from inside
    /// this add-credential sheet. Nous uses device-code, not PKCE — the
    /// regular `OAuthFlowController` silently stalls, so we route Nous
    /// through ``NousSignInSheet`` instead.
    @State private var showNousSignIn: Bool = false

    private var catalog: ModelCatalogService { ModelCatalogService(context: viewModel.context) }

    private func oauthGate(for rawID: String) -> CredentialPoolsOAuthGate {
        CredentialPoolsOAuthGate.resolve(providerID: rawID, catalog: catalog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Credential")
                .font(.headline)
            if !oauthStarted {
                configSection
            } else {
                oauthSection
            }
            Divider()
            footer
        }
        .padding()
        .frame(minWidth: 600, minHeight: 460)
        .onAppear {
            providers = catalog.loadProviders()
        }
        // Auto-close the sheet once a credential is actually saved. We key
        // off `succeeded` which the controller sets only when hermes exited
        // zero AND the output has no failure markers. The 0.8s delay lets the
        // user see the success banner before the sheet disappears.
        .onChange(of: viewModel.oauthFlow.succeeded) { _, newValue in
            guard newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                onDismiss()
            }
        }
        // Nous sign-in is a parallel flow that bypasses OAuthFlowController.
        // When it completes, the parent list refreshes from auth.json just
        // like it does after a regular OAuth add — so we dismiss the
        // AddCredentialSheet after a short delay.
        .sheet(isPresented: $showNousSignIn) {
            NousSignInSheet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Step 1: provider + type + label + optional API key

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Provider").font(.caption).foregroundStyle(.secondary)
                HStack {
                    // Free-text first so providers missing from the catalog
                    // (e.g. "nous") are still addable.
                    TextField("e.g. anthropic", text: $providerID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Menu("Browse") {
                        ForEach(providers) { provider in
                            Button(provider.providerName + " (\(provider.providerID))") {
                                providerID = provider.providerID
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Credential Type").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $authType) {
                    ForEach(AuthType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. team-prod", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            if authType == .apiKey {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                oauthGuidance
            }
        }
    }

    /// Renders either the standard PKCE preamble, the Nous-specific
    /// "sign in with the dedicated sheet" affordance, or a CLI fallback —
    /// whichever matches the provider the user has typed.
    @ViewBuilder
    private var oauthGuidance: some View {
        switch oauthGate(for: providerID) {
        case .ok, .providerEmpty:
            oauthPreamble
        case .useNousSignIn:
            nousSignInPreamble
        case .useCLI(let provider):
            cliFallbackPreamble(for: provider)
        }
    }

    private var nousSignInPreamble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Nous Portal uses a dedicated sign-in flow.")
                    .font(.caption)
            }
            Text("We'll open the Nous Portal approval page in your browser and show the device code here. No code-paste step.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cliFallbackPreamble(for provider: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("`\(provider)` uses a different sign-in flow.")
                    .font(.caption)
            }
            Text("Run `hermes auth add \(provider)` in a terminal to finish sign-in. In-app support for this provider is coming in a follow-up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Brief explanation shown before the user clicks "Start OAuth". Sets
    /// expectations about the embedded-terminal flow so the browser window
    /// and code-paste step aren't surprises.
    private var oauthPreamble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clicking Start OAuth opens the provider's authorization page in your browser. After you approve, copy the code the provider displays and paste it back into the terminal that appears next.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The terminal is a real TTY — paste with ⌘V, press Return, and wait for the process to exit with \"login succeeded\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Step 2: OAuth — URL button, code field, live output log

    private var oauthSection: some View {
        // Pull the observable controller into a local so the view redraws
        // when its @Observable properties change.
        let flow = viewModel.oauthFlow
        return VStack(alignment: .leading, spacing: 10) {
            oauthHeader(flow: flow)
            urlBlock(flow: flow)
            codeEntryBlock(flow: flow)
            outputLogBlock(flow: flow)
        }
    }

    @ViewBuilder
    private func oauthHeader(flow: OAuthFlowController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
            Text("OAuth login for \(viewModel.oauthProvider)")
                .font(.headline)
            Spacer()
            if flow.isRunning {
                ProgressView().controlSize(.small)
            } else if flow.succeeded {
                Label("Succeeded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let err = flow.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    /// Authorization URL block. Hermes prints the URL on startup; we detect
    /// it via regex and expose a prominent Open + Copy pair. The URL keeps
    /// showing even after the browser is opened so users can paste it into
    /// a different browser profile if needed.
    @ViewBuilder
    private func urlBlock(flow: OAuthFlowController) -> some View {
        if let url = flow.authorizationURL {
            VStack(alignment: .leading, spacing: 6) {
                Label("Authorization URL", systemImage: "link")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        flow.openURLInBrowser()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
            .background(.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if flow.isRunning {
            // Still waiting for hermes to print the URL — usually <1s.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for authorization URL…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Authorization code input. Only active once hermes has printed its
    /// "Authorization code:" prompt so users can't submit before hermes is
    /// ready to receive input.
    @ViewBuilder
    private func codeEntryBlock(flow: OAuthFlowController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Authorization Code", systemImage: "keyboard")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("After approving in your browser, the provider shows a code. Paste it below and submit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Paste code here…", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(!flow.awaitingCode)
                    .onSubmit { submitCode(flow: flow) }
                Button("Submit") { submitCode(flow: flow) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.awaitingCode || authCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !flow.awaitingCode && flow.isRunning {
                Text("Waiting for hermes to prompt for the code…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Live output log — useful for diagnostics if the flow stalls or errors.
    @ViewBuilder
    private func outputLogBlock(flow: OAuthFlowController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Output", systemImage: "text.alignleft")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView {
                Text(flow.output.isEmpty ? "(no output yet)" : flow.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func submitCode(flow: OAuthFlowController) {
        let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.submitOAuthCode(trimmed)
        authCode = ""
    }

    // MARK: - Footer (buttons)

    private var footer: some View {
        HStack {
            Spacer()
            if oauthStarted {
                Button("Close") {
                    // Closing mid-flow terminates hermes so we don't leave a
                    // zombie process waiting for stdin forever.
                    viewModel.cancelOAuth()
                    onDismiss()
                }
            } else {
                Button("Cancel") { onDismiss() }
                if authType == .apiKey {
                    Button("Add") {
                        viewModel.addAPIKey(provider: providerID, apiKey: apiKey, label: label)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(providerID.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    oauthActionButton
                }
            }
        }
    }

    /// Gate-aware OAuth primary action. For PKCE providers it's the
    /// unchanged "Start OAuth" button; for Nous it's "Sign in to Nous
    /// Portal" (opens ``NousSignInSheet``); for other device-code /
    /// external providers it's a disabled button with a CLI hint inline.
    @ViewBuilder
    private var oauthActionButton: some View {
        switch oauthGate(for: providerID) {
        case .providerEmpty:
            Button("Start OAuth") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .ok:
            Button("Start OAuth") {
                viewModel.startOAuth(provider: providerID, label: label)
                oauthStarted = true
            }
            .buttonStyle(.borderedProminent)
        case .useNousSignIn:
            Button("Sign in to Nous Portal") {
                showNousSignIn = true
            }
            .buttonStyle(.borderedProminent)
        case .useCLI:
            Button("Start OAuth") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }
}
