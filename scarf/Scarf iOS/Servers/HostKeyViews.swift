import SwiftUI
import ScarfCore
import ScarfIOS
import ScarfDesign

/// Reads one endpoint's host-key record off the main actor and keeps it
/// current: connections in any tab write the store on an event loop, and
/// `HostKeyPinStore.didChangeNotification` tells us to re-read.
@Observable
@MainActor
final class HostKeyRecordModel {
    let endpoint: HostKeyEndpoint
    private(set) var record: HostKeyRecord?
    private(set) var loaded = false
    private let store: HostKeyPinStore

    init(endpoint: HostKeyEndpoint, store: HostKeyPinStore = .shared) {
        self.endpoint = endpoint
        self.store = store
    }

    func reload() async {
        record = await store.recordOffMain(for: endpoint)
        loaded = true
    }

    /// Re-read whenever the store changes, for as long as the caller's task lives.
    func observe() async {
        await reload()
        for await _ in NotificationCenter.default.notifications(named: HostKeyPinStore.didChangeNotification) {
            await reload()
        }
    }

    /// Pin the key the server presented in its refused connection. Only the
    /// fingerprint the user was shown is accepted (see `trustRejectedKey`).
    func trustPresentedKey(fingerprint: String) async -> Bool {
        let trusted = await store.trustRejectedKeyOffMain(for: endpoint, expectedFingerprint: fingerprint)
        await reload()
        return trusted
    }
}

/// System tab section: the pinned fingerprint (read-only) and, when the
/// server presented a different key, the identity-change card.
struct HostKeySection: View {
    @State private var model: HostKeyRecordModel

    init(endpoint: HostKeyEndpoint) {
        _model = State(initialValue: HostKeyRecordModel(endpoint: endpoint))
    }

    var body: some View {
        Group {
            if let record = model.record, let rejected = record.rejected {
                Section {
                    HostKeyChangeCard(model: model, pinned: record.pinned, presented: rejected)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
            }
            Section {
                if let pinned = model.record?.pinned {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint")
                            .font(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                        FingerprintText(value: pinned.fingerprint)
                    }
                    .accessibilityElement(children: .combine)
                    .listRowBackground(ScarfColor.backgroundSecondary)
                    LabeledContent("Key type", value: pinned.algorithm)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                    LabeledContent("Trusted since", value: pinned.seenAt.formatted(date: .abbreviated, time: .shortened))
                        .listRowBackground(ScarfColor.backgroundSecondary)
                } else if model.loaded {
                    Text("Not saved yet. ScarfGo saves this server’s host key the first time it connects.")
                        .font(.callout)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .listRowBackground(ScarfColor.backgroundSecondary)
                }
            } header: {
                Text("Host key")
            } footer: {
                Text("ScarfGo checks this key on every connection and refuses to connect if the server presents a different one.")
                    .font(.caption)
            }
        }
        .task { await model.observe() }
    }
}

/// "Server identity changed": both fingerprints and a deliberate, confirmed
/// "Trust New Key". Shared by the System tab and onboarding's failure step.
struct HostKeyChangeCard: View {
    let model: HostKeyRecordModel
    let pinned: HostKeyFingerprint
    let presented: HostKeyFingerprint

    @State private var confirming = false
    @State private var isTrusting = false
    /// The fingerprint the user is confirming, captured when they first tap
    /// "Trust New Key". The dialog shows it and the trust call passes it, so
    /// a key the server presents while the dialog is open can never be the
    /// one that gets trusted (the store's exact-match check refuses it).
    @State private var pendingFingerprint: String?
    /// Set when a trust was refused because the server presented yet
    /// another key; the card above already shows that newer key.
    @State private var supersededFingerprint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Server identity changed", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(ScarfColor.danger)
            Text("ScarfGo refused to connect to \(model.endpoint.displayName) because it presented a different host key than the one ScarfGo trusts. This is expected if the server was reinstalled or its SSH keys were regenerated. Otherwise, someone may be intercepting the connection.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            fingerprintRow(title: "Trusted key", value: pinned.fingerprint)
            fingerprintRow(title: "Presented key", value: presented.fingerprint)
            Text("Compare the presented key with the server’s own: run ssh-keygen -lf on its host key, for example /etc/ssh/ssh_host_ed25519_key.pub.")
                .font(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let superseded = supersededFingerprint, superseded != presented.fingerprint {
                Label("The server presented a different key again, so nothing was trusted. Review the presented key above before you decide.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ScarfColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                pendingFingerprint = presented.fingerprint
                supersededFingerprint = nil
                confirming = true
            } label: {
                HStack {
                    if isTrusting { ProgressView().tint(ScarfColor.onDanger) }
                    Text("Trust New Key")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ScarfDestructiveButton())
            .disabled(isTrusting)
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Trust the new host key?",
            isPresented: $confirming,
            titleVisibility: .visible,
            presenting: pendingFingerprint
        ) { fingerprint in
            Button("Trust New Key", role: .destructive) {
                Task {
                    isTrusting = true
                    let trusted = await model.trustPresentedKey(fingerprint: fingerprint)
                    if !trusted { supersededFingerprint = fingerprint }
                    pendingFingerprint = nil
                    isTrusting = false
                }
            }
            Button("Cancel", role: .cancel) { pendingFingerprint = nil }
        } message: { fingerprint in
            Text("You are about to trust \(fingerprint). Only continue if you know why the server’s key changed and this fingerprint matches the server. If someone is intercepting the connection, trusting this key lets them read and change everything ScarfGo sends, including your chats.")
        }
    }

    private func fingerprintRow(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            FingerprintText(value: value)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Onboarding's failure step: the change card when the endpoint has an
/// unresolved identity change, nothing otherwise.
struct OnboardingHostKeyChangeCard: View {
    @State private var model: HostKeyRecordModel

    init(endpoint: HostKeyEndpoint) {
        _model = State(initialValue: HostKeyRecordModel(endpoint: endpoint))
    }

    var body: some View {
        // A VStack, not a Group: `.task` on an empty Group never runs, so
        // the record would never load.
        VStack(alignment: .leading, spacing: 0) {
            if let record = model.record, let rejected = record.rejected {
                HostKeyChangeCard(model: model, pinned: record.pinned, presented: rejected)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                            .fill(ScarfColor.backgroundSecondary)
                    )
            }
        }
        .task { await model.observe() }
    }
}

/// A `SHA256:…` fingerprint, never truncated or shrunk. Long values wrap
/// only at fixed 8-character chunk boundaries (zero-width spaces after the
/// `SHA256:` prefix), so the text system never hyphenates mid-value and an
/// inserted "-" can't be mistaken for part of the key.
///
/// Copying goes through a long-press "Copy Fingerprint" menu that puts the
/// CLEAN value on the pasteboard. `.textSelection(.enabled)` is deliberately
/// not used: it would copy the displayed string, zero-width spaces included,
/// and a pasted fingerprint with invisible characters fails a text compare
/// against `ssh-keygen -lf` output.
struct FingerprintText: View {
    let value: String

    var body: some View {
        Text(verbatim: Self.chunked(value))
            .font(.footnote.monospaced())
            .fixedSize(horizontal: false, vertical: true)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy Fingerprint", systemImage: "doc.on.doc")
                }
            }
            .accessibilityLabel(Text(verbatim: value))
    }

    /// `SHA256:` + the base64 body split into 8-character chunks joined by
    /// U+200B ZERO WIDTH SPACE (a line-break opportunity that renders as
    /// nothing and never hyphenates).
    static func chunked(_ fingerprint: String) -> String {
        let prefix = "SHA256:"
        guard fingerprint.hasPrefix(prefix) else { return fingerprint }
        let body = Array(fingerprint.dropFirst(prefix.count))
        let chunks = stride(from: 0, to: body.count, by: 8).map {
            String(body[$0..<min($0 + 8, body.count)])
        }
        return prefix + "\u{200B}" + chunks.joined(separator: "\u{200B}")
    }
}
