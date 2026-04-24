import SwiftUI
import AppKit

/// In-app sign-in sheet for Nous Portal — hosts a ``NousAuthFlow`` and
/// renders one of four sub-views keyed on `flow.state`. Reached from the
/// model picker's Nous Portal row, the Auxiliary tab's per-task toggle,
/// and Credential Pools when the selected provider is `nous`.
///
/// UX contract with the caller:
///
/// - Sheet is presented via `.sheet(isPresented:)` from the caller.
/// - Parent owns the `isPresented` binding and a `@State var` for the
///   dismiss trigger.
/// - `onSignedIn` fires on success so the caller can refresh subscription
///   state (e.g. re-query ``NousSubscriptionService``) before the sheet
///   auto-dismisses ~1.2s later.
struct NousSignInSheet: View {
    @Environment(\.serverContext) private var serverContext
    @Environment(\.dismiss) private var dismiss

    /// Fires on `.success`. Callers use this to refresh their cached
    /// ``NousSubscriptionState`` so the new "Subscription active" chip
    /// shows immediately without waiting for a full view reload.
    var onSignedIn: () -> Void = {}

    @State private var flow: NousAuthFlow?
    @State private var successDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 440, minHeight: 340)
        .onAppear {
            if flow == nil {
                let f = NousAuthFlow(context: serverContext)
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

    private var flowState: NousAuthFlow.State {
        flow?.state ?? .idle
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key.fill")
                .foregroundStyle(.tint)
            Text("Sign in to Nous Portal")
                .font(.headline)
            Spacer()
            if case .waitingForApproval = flowState {
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
            } else if case .starting = flowState {
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
            } else {
                Button("Close") { dismiss() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - State-keyed content

    @ViewBuilder
    private var content: some View {
        switch flowState {
        case .idle, .starting:
            startingView
        case .waitingForApproval(let code, let url):
            waitingView(userCode: code, verificationURL: url)
        case .success:
            successView
        case .failure(let reason, let billingURL):
            failureView(reason: reason, billingURL: billingURL)
        }
    }

    // MARK: - .starting

    private var startingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Contacting Nous Portal…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("This may take a few seconds.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - .waitingForApproval

    @ViewBuilder
    private func waitingView(userCode: String, verificationURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Approve in your browser")
                    .font(.headline)
                Text("We opened the Nous Portal approval page. Confirm this code matches what it shows, then approve.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            userCodeBadge(userCode)

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(verificationURL)
                } label: {
                    Label("Open approval page again", systemImage: "safari")
                }
                .controlSize(.small)
                Spacer()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func userCodeBadge(_ code: String) -> some View {
        HStack(spacing: 10) {
            Text(code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Button {
                copyToPasteboard(code)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
        }
    }

    // MARK: - .success

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 48))
            Text("Signed in to Nous Portal")
                .font(.headline)
            Text("Your tools will now route through your subscription.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - .failure

    @ViewBuilder
    private func failureView(reason: String, billingURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(billingURL == nil ? "Sign-in didn't complete" : "Subscription required")
                    .font(.headline)
            }

            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let billingURL {
                Button {
                    NSWorkspace.shared.open(billingURL)
                } label: {
                    Label("Subscribe", systemImage: "creditcard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 10) {
                Button("Try again") { flow?.start() }
                    .buttonStyle(.bordered)
                Button("Copy error") {
                    let payload = (flow?.output.isEmpty == false) ? flow!.output : reason
                    copyToPasteboard(payload)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Close") { dismiss() }
            }
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }
}
