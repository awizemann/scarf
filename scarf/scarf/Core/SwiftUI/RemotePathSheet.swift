import SwiftUI
import ScarfCore

/// Remote-path picker for any flow that hands a filesystem path to a CLI
/// running on the *remote* host. Used when the active `ServerContext` is
/// `.ssh` — `NSOpenPanel` / `NSSavePanel` browse the user's Mac, which is
/// the wrong host: the command runs over SSH, so a Mac path either fails
/// (the directory doesn't exist there) or silently writes the artifact to
/// a Mac-shaped path on the remote box where the user will never find it.
///
/// The sheet takes a remote path string and verifies it via the active
/// transport before handing it back. `mode` distinguishes "must already
/// exist" (import) from "we're about to write here" (export), each with
/// its own validation.
///
/// Lives in Core rather than a feature folder because both Profiles
/// (zip import/export) and Sessions (jsonl export) need it —
/// `expectedExtension` + `extensionNote` keep the per-caller copy exact.
struct RemotePathSheet: View {
    enum Mode {
        /// Import flow: the file must already exist on the remote.
        case existingFile
        /// Export flow: we'll be writing to the path. Permissive on
        /// non-existence (that's expected); warn on existing dir or
        /// unexpected extension.
        case writableFile(initialName: String)
    }

    let context: ServerContext
    let title: String
    let prompt: String
    let placeholder: String
    let confirmLabel: String
    let mode: Mode
    /// Expected extension WITHOUT the leading dot (e.g. `zip`, `jsonl`).
    let expectedExtension: String
    /// Sentence appended to the wrong-extension warning, explaining what
    /// the command actually reads/writes.
    let extensionNote: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var path: String = ""
    @State private var verification: Verification = .idle

    private enum Verification: Equatable {
        case idle
        case verifying
        case ok(String)
        case warn(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: path) { _, _ in
                        if verification != .idle { verification = .idle }
                    }
                Button("Verify") { Task { await verify() } }
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty
                              || verification == .verifying)
            }
            verificationBadge
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmLabel) {
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onConfirm(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if case .writableFile(let initialName) = mode, path.isEmpty {
                path = "~/" + initialName
            }
        }
    }

    @ViewBuilder
    private var verificationBadge: some View {
        switch verification {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking on \(context.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok(let detail):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(detail).font(.caption)
            }
        case .warn(let detail):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(detail).font(.caption)
            }
        }
    }

    private func verify() async {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        verification = .verifying
        let snapshot = context
        let snapshotMode = mode
        let ext = expectedExtension
        let note = extensionNote
        let result: Verification = await Task.detached {
            let transport = snapshot.makeTransport()
            let exists = transport.fileExists(trimmed)
            switch snapshotMode {
            case .existingFile:
                guard exists else {
                    return .warn("Path doesn't exist on \(snapshot.displayName).")
                }
                guard let stat = transport.stat(trimmed) else {
                    return .warn("Found, but couldn't stat — check permissions.")
                }
                if stat.isDirectory {
                    return .warn("Path is a directory, not a file.")
                }
                if !trimmed.lowercased().hasSuffix(".\(ext)") {
                    return .warn("File found, but extension isn't `.\(ext)`. \(note)")
                }
                return .ok("File found on \(snapshot.displayName).")
            case .writableFile:
                if exists {
                    if let stat = transport.stat(trimmed), stat.isDirectory {
                        return .warn("Path is a directory. Choose a file path that doesn't yet exist.")
                    }
                    return .warn("File already exists on \(snapshot.displayName) — export will overwrite it.")
                }
                if !trimmed.lowercased().hasSuffix(".\(ext)") {
                    return .warn("Extension isn't `.\(ext)`. \(note)")
                }
                return .ok("Path is available on \(snapshot.displayName).")
            }
        }.value
        verification = result
    }
}
