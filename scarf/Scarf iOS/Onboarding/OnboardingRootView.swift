import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

/// Owns the `OnboardingViewModel` and renders the current step.
/// Each step gets its own small view; the view switch is driven by
/// `vm.step`.
struct OnboardingRootView: View {
    /// ServerID under which this onboarding run writes the key +
    /// config. M9: the ServerListView reserves a fresh ID when the
    /// user taps "+"; the RootModel passes it through to us; we pass
    /// it into OnboardingViewModel which uses the ID-keyed store APIs.
    let targetServerID: ServerID
    let onFinished: @MainActor () async -> Void
    /// Invoked when the user cancels before completing. M9: pops us
    /// back to the server list instead of leaving the user stuck on
    /// step 1 with nowhere to go. Optional for callers that don't
    /// need cancel (shouldn't be any, but keeps the API forgiving).
    let onCancel: @MainActor () -> Void
    /// Whether the Cancel button should appear in the nav bar
    /// (issue #55). False on the first-run onboarding where there
    /// is no `.serverList` to fall back to — showing Cancel there
    /// fired the action but the state machine routed straight back
    /// into onboarding, so the button looked broken to TestFlight
    /// users.
    let canCancel: Bool

    @State private var vm: OnboardingViewModel

    init(
        targetServerID: ServerID,
        canCancel: Bool = true,
        onFinished: @escaping @MainActor () async -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        self.targetServerID = targetServerID
        self.canCancel = canCancel
        self.onFinished = onFinished
        self.onCancel = onCancel
        let service = CitadelSSHService()
        _vm = State(initialValue: OnboardingViewModel(
            keyStore: KeychainSSHKeyStore(),
            configStore: UserDefaultsIOSServerConfigStore(),
            tester: service,
            keyGenerator: { try service.generateEd25519Key() },
            targetServerID: targetServerID
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch vm.step {
                case .serverDetails:   ServerDetailsStep(vm: vm)
                case .keySource:       KeySourceStep(vm: vm)
                case .generate:        GenerateKeyStep(vm: vm)
                case .importKey:       ImportKeyStep(vm: vm)
                case .showPublicKey:   ShowPublicKeyStep(vm: vm)
                case .testConnection:  TestConnectionStep(vm: vm)
                case .testFailed(let reason): TestFailedStep(vm: vm, reason: reason)
                case .connected:       ConnectedStep()
                }
            }
            .navigationTitle("Connect to Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Cancel only makes sense while we haven't yet
                    // completed — once the connection-test passes we
                    // auto-forward to onFinished so there's nothing
                    // to cancel. Hiding the button then also keeps
                    // users from accidentally wiping a just-saved
                    // server mid-race.
                    //
                    // Also hidden on first-run onboarding (issue #55):
                    // there is no server list to return to, so Cancel
                    // would either be inert (state machine looping
                    // back into onboarding) or confusing (an empty
                    // server list with no path forward). Better to
                    // not show the affordance at all.
                    if case .connected = vm.step {
                        EmptyView()
                    } else if canCancel {
                        Button("Cancel") {
                            onCancel()
                        }
                    }
                }
            }
        }
        .onChange(of: vm.step) { _, new in
            if case .connected = new {
                Task { await onFinished() }
            }
        }
    }
}

// MARK: - Steps

private struct ServerDetailsStep: View {
    let vm: OnboardingViewModel

    var body: some View {
        Form {
            Section("Remote host") {
                TextField("hostname or IP", text: Bindable(vm).host)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("username (optional)", text: Bindable(vm).user)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("port (default 22)", text: Bindable(vm).portText)
                    .keyboardType(.numberPad)
                TextField("nickname (optional)", text: Bindable(vm).displayName)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    vm.advanceFromServerDetails()
                } label: {
                    HStack {
                        Spacer()
                        Text("Next")
                            .bold()
                        Spacer()
                    }
                }
                .disabled(!vm.serverDetailsValidation.canAdvance)
            }
        }
    }
}

private struct KeySourceStep: View {
    let vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("SSH key")
                .font(.title2)
                .bold()
            Text("Scarf authenticates to your Hermes host with an SSH key. You can generate a new one on this device, or import one you already use.")
                .multilineTextAlignment(.center)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button {
                    vm.pickKeyChoice(.generate)
                } label: {
                    Label("Generate a new key", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(ScarfPrimaryButton())

                Button {
                    vm.pickKeyChoice(.importExisting)
                } label: {
                    Label("Import existing key", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Spacer()
        }
        .padding(.top)
    }
}

private struct GenerateKeyStep: View {
    let vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Generating Ed25519 keypair…")
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .task {
            await vm.generateKey()
        }
    }
}

private struct ImportKeyStep: View {
    let vm: OnboardingViewModel
    @State private var publicKey: String = ""

    var body: some View {
        Form {
            Section("Paste your private key") {
                TextEditor(text: Bindable(vm).importPEM)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
            }
            Section("Paste the matching public-key line") {
                TextEditor(text: $publicKey)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Button("Import") {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime]
                    _ = vm.importKey(
                        publicKey: publicKey,
                        deviceComment: "scarf-ios-imported",
                        iso8601Date: iso.string(from: Date())
                    )
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct ShowPublicKeyStep: View {
    let vm: OnboardingViewModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add this public key to the remote")
                    .font(.title3)
                    .bold()
                Text("Append the line below to `~/.ssh/authorized_keys` on the Hermes host. Once added, tap **I've added this key** to test the connection.")
                    .font(.callout)
                    .foregroundStyle(ScarfColor.foregroundMuted)

                if let bundle = vm.keyBundle {
                    Text(OnboardingLogic.authorizedKeysLine(for: bundle))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ScarfColor.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string =
                            OnboardingLogic.authorizedKeysLine(for: bundle)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button {
                    Task { await vm.confirmPublicKeyAdded() }
                } label: {
                    HStack {
                        Spacer()
                        Text("I've added this key")
                            .bold()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(vm.isWorking)
            }
            .padding()
        }
    }
}

private struct TestConnectionStep: View {
    let vm: OnboardingViewModel

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Testing connection to \(vm.host)…")
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }
}

private struct TestFailedStep: View {
    let vm: OnboardingViewModel
    let reason: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ScarfColor.warning)
                    .font(.title3)
                    .bold()
                Text(reason)
                    .font(.callout)

                HStack {
                    Button("Back") {
                        vm.goBackToServerDetails()
                    }
                    .buttonStyle(.bordered)

                    Button("Retry") {
                        Task { await vm.runConnectionTest() }
                    }
                    .buttonStyle(ScarfPrimaryButton())
                }
            }
            .padding()
        }
    }
}

private struct ConnectedStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(ScarfColor.success)
            Text("Connected")
                .font(.title2)
                .bold()
            Text("Loading dashboard…")
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
    }
}
