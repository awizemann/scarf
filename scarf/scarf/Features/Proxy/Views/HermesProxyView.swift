import SwiftUI
import ScarfCore
import ScarfDesign

/// Hermes Proxy panel — start/stop the local OpenAI-compatible proxy
/// that forwards requests to the user's OAuth-authenticated upstream
/// provider (Nous Portal in v0.14; more adapters land in later Hermes
/// versions). Capability-gated by the sidebar's `hasHermesProxy`
/// flag so the route is never reached on pre-v0.14 hosts.
struct HermesProxyView: View {
    @State private var viewModel: HermesProxyViewModel

    init(context: ServerContext) {
        _viewModel = State(initialValue: HermesProxyViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScarfPageHeader(
                "Hermes Proxy",
                subtitle: "Expose a Hermes subscription as an OpenAI-compatible endpoint"
            ) {
                statusBadge
            }
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                    if !viewModel.isLocal {
                        remoteHostNotice
                    } else {
                        controlsCard
                        endpointCard
                        logCard
                        helpCard
                    }
                }
                .padding(ScarfSpace.s4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ScarfColor.backgroundPrimary)
        .task { await viewModel.refreshProviders() }
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        if viewModel.service.isRunning {
            ScarfBadge("Running", kind: .success)
        } else {
            ScarfBadge("Stopped", kind: .neutral)
        }
    }

    // MARK: - Cards

    private var controlsCard: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                Text("Controls")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                HStack(spacing: ScarfSpace.s3) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        Picker("", selection: $viewModel.providerSelection) {
                            ForEach(viewModel.availableProviders, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                        .disabled(viewModel.service.isRunning)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        TextField("8645", text: $viewModel.portText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Port")
                            .font(ScarfFont.mono)
                            .frame(maxWidth: 120)
                            .disabled(viewModel.service.isRunning)
                    }
                    Spacer()
                    Button("Start") { viewModel.start() }
                        .buttonStyle(ScarfPrimaryButton())
                        .disabled(!viewModel.canStart)
                    Button("Stop") { viewModel.stop() }
                        .buttonStyle(ScarfDestructiveButton())
                        .disabled(!viewModel.canStop)
                }
                if let err = viewModel.service.lastError {
                    Text(err)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.danger)
                }
            }
        }
    }

    @ViewBuilder
    private var endpointCard: some View {
        if let endpoint = viewModel.service.endpoint {
            ScarfCard {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    Text("Endpoint")
                        .scarfStyle(.captionUppercase)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    HStack(spacing: ScarfSpace.s2) {
                        Text(endpoint.absoluteString)
                            .font(ScarfFont.mono)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            #if canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint.absoluteString, forType: .string)
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy endpoint URL")
                    }
                    if let provider = viewModel.service.routedProvider {
                        Text("Forwarding via \(provider). Use any bearer token in your client — the proxy attaches your real credential.")
                            .scarfStyle(.footnote)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
            }
        }
    }

    private var logCard: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                HStack {
                    Text("Log")
                        .scarfStyle(.captionUppercase)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer()
                    if !viewModel.service.logLines.isEmpty {
                        Button("Clear") { viewModel.clearLog() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                if viewModel.service.logLines.isEmpty {
                    Text("No output yet. Press Start to launch the proxy.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                } else {
                    ScrollViewReader { scroller in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(viewModel.service.logLines.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(ScarfFont.monoSmall)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(idx)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                        .onChange(of: viewModel.service.logLines.count) { _, newCount in
                            if newCount > 0 {
                                scroller.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var helpCard: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Text("Using the proxy")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Text("Point any OpenAI-compatible client (Codex CLI, Aider, Cline, VS Code Continue) at the endpoint above. The proxy attaches your Hermes-managed credentials, so any bearer token in the client is accepted.")
                    .scarfStyle(.body)
                Text("Sign in first with `hermes login \(viewModel.providerSelection)` if the adapter reports not authenticated.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
        }
    }

    private var remoteHostNotice: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                Text("Local server only")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.warning)
                Text("Hermes Proxy currently runs only against the local server. SSH-deployed servers would need an additional port-forward step that isn't wired in this release.")
                    .scarfStyle(.body)
            }
        }
    }
}
