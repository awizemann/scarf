import SwiftUI
import AppKit

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

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 440, minHeight: 320)
        .onAppear {
            if flow == nil {
                let f = SpotifyAuthFlow(context: serverContext)
                flow = f
                f.start()
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
                Button("Try again") {
                    flow?.start()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
