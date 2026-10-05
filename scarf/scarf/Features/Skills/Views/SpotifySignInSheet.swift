import SwiftUI
import ScarfDesign
import AppKit
import ScarfCore

/// In-app sign-in sheet for the Spotify skill (Hermes v2026.4.23+).
/// Hosts a `SpotifyAuthFlow` and renders one of five sub-views keyed
/// on `flow.state`. Reached from the Skills sidebar (when the spotify
/// skill is selected and not yet authenticated) and from any future
/// "Auxiliary providers" surface.
///
/// UX contract with the caller:
/// - Sheet presented via `.sheet(isPresented:)`.
/// - Parent owns the binding.
/// - `onSignedIn` fires on `.success` so callers can refresh whatever
///   view was showing the "not authed" affordance.
///
/// Mirrors `NousSignInSheet` (v2.3) in shape — same lifecycle, same
/// patience model, same auto-dismiss-on-success.
struct SpotifySignInSheet: View {
    @Environment(\.serverContext) private var serverContext
    @Environment(\.dismiss) private var dismiss

    var onSignedIn: () -> Void = {}

    @State private var flow: SpotifyAuthFlow?
    @State private var successDismissTask: Task<Void, Never>?
    /// What the sheet shows before (or instead of) the auth run — S07-F6.
    @State private var gate: Gate = .checking
    @State private var clientIDDraft = ""
    /// The redirect URI Hermes will listen on — the host's own setting when
    /// it has one, else Hermes's default.
    @State private var redirectURI = SpotifyAuthFlow.redirectURI

    /// A first-time LOCAL sign-in needs a Client ID Hermes would otherwise
    /// ask for on a terminal; a REMOTE window cannot finish the OAuth
    /// callback from here at all, so it gets the command to run instead.
    enum Gate: Equatable {
        case checking
        case needsClientID
        case remote
        case running
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 440, minHeight: 320)
        .task {
            guard flow == nil else { return }
            let f = SpotifyAuthFlow(context: serverContext)
            flow = f
            let setup = await f.loadSetup()
            redirectURI = setup.redirectURI
            if serverContext.isRemote {
                gate = .remote
            } else if setup.clientIDKnown {
                gate = .running
                f.start()
            } else {
                gate = .needsClientID
            }
        }
        .onDisappear {
            successDismissTask?.cancel()
            flow?.cancel()
        }
        .onChange(of: flowState) { _, newValue in
            if case .success = newValue {
                onSignedIn()
                successDismissTask?.cancel()
                successDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if !Task.isCancelled { dismiss() }
                }
            }
        }
    }

    // Captures `flow.state` so `.onChange(of:)` works (Equatable) without
    // forcing the whole flow into the change closure (it isn't Equatable).
    private var flowState: SpotifyAuthFlow.State {
        flow?.state ?? .idle
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.green)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to Spotify")
                    .font(.headline)
                Text("Authorise Hermes to control your Spotify account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                flow?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch gate {
        case .checking:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsClientID:
            clientIDView
        case .remote:
            remoteView
        case .running:
            flowContent
        }
    }

    /// First-time setup: the steps Hermes's own wizard prints
    /// (`hermes_cli/auth_spotify.py:270-286` @ v2026.9.24), and a field for
    /// the Client ID it would have read from a terminal.
    private var clientIDView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify needs a Client ID from your own Spotify developer app. This is a one-time step.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open the Spotify developer dashboard and click Create app.")
                Text("2. Add this Redirect URI and select Web API:")
                HStack {
                    Text(verbatim: redirectURI)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(redirectURI, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 14)
                Text("3. Save, open the app's Settings and copy its Client ID here.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Open Spotify Dashboard") {
                if let url = URL(string: SpotifyAuthFlow.dashboardURL) { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
            TextField("Client ID", text: $clientIDDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(continueWithClientID)
            if !clientIDDraft.isEmpty, !SpotifyAuthFlow.isPlausibleClientID(clientIDDraft) {
                Text("A Client ID is letters and digits only (usually 32 characters).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Continue", action: continueWithClientID)
                    .buttonStyle(ScarfPrimaryButton())
                    .disabled(!SpotifyAuthFlow.isPlausibleClientID(clientIDDraft))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func continueWithClientID() {
        guard SpotifyAuthFlow.isPlausibleClientID(clientIDDraft), let flow else { return }
        gate = .running
        flow.start(clientID: clientIDDraft)
    }

    /// A remote window: the OAuth callback listens on the HOST's loopback,
    /// so sign-in has to run there, with the port forwarded to this Mac.
    private var remoteView: some View {
        let line = SpotifyAuthFlow.remoteCommandLine(for: serverContext, redirectURI: redirectURI)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Spotify sign-in has to run on \(serverContext.displayName), where Hermes runs. Its browser callback goes to port \(String(SpotifyAuthFlow.callbackPort(of: redirectURI))) on that host, so Scarf can't complete it from this window.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Run this in Terminal on this Mac. It connects with the callback port forwarded, then asks for a Client ID the first time and prints the sign-in link — open that link in your browser here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                }
                Button("Open in Terminal") {
                    let script = NSAppleScript(source: GatewaySetupTerminalCommand.appleScript(forShellLine: line))
                    var err: NSDictionary?
                    script?.executeAndReturnError(&err)
                }
                .buttonStyle(ScarfPrimaryButton())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var flowContent: some View {
        switch flow?.state ?? .idle {
        case .idle, .starting:
            startingView
        case .waitingForApproval(let url):
            waitingView(url: url)
        case .verifying:
            verifyingView
        case .success:
            successView
        case .failure(let reason):
            failureView(reason: reason)
        }
    }

    private var startingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting `hermes auth spotify`…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func waitingView(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser approval…")
                    .font(.callout)
            }
            Text("Scarf opened the authorisation URL in your default browser. Sign in with your Spotify account and approve the requested permissions to complete sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .controlSize(.small)
                Button("Open") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verifyingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Verifying token…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("Spotify connected")
                .font(.headline)
            Text("You can now use the spotify skill from chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Sign-in failed")
                    .font(.headline)
                Spacer()
            }
            Text(reason)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if !clientIDDraft.isEmpty {
                    // The typed ID may be the problem (a typo, or the
                    // Redirect URI missing from that Spotify app).
                    Button("Change Client ID") { gate = .needsClientID }
                }
                Button("Try again") {
                    flow?.start(clientID: clientIDDraft.isEmpty ? nil : clientIDDraft)
                }
                .buttonStyle(ScarfPrimaryButton())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
