import SwiftUI
import ScarfCore
import ScarfDesign

/// Non-modal notice that Scarf had to work around damage in
/// `~/.hermes/scarf/projects.json`.
///
/// The file is agent-writable, so this is a thing users will actually
/// hit; Phase 1 made the reader survive it silently, and silence is
/// exactly the problem — a project vanishing from the sidebar with no
/// explanation reads as data loss. The banner says what happened and
/// points at the copy that was kept.
///
/// The reveal action is local-only: on an SSH context the backup lives
/// on the remote host, where Finder cannot go, so the path is shown as
/// text the user can read (and select) instead.
struct RegistryDamageBanner: View {
    let damage: RegistryDamageNotice
    let isRemote: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(damage.headline)
                    .font(.caption.bold())
                Text(damage.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isRemote, let path = damage.revealPath {
                    // Remote host: no Finder to reveal into, so the
                    // path itself is the useful thing.
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            // Title, explanation and path read as one announcement; the
            // buttons stay outside it.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if !isRemote, let path = damage.revealPath {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Dismiss"))
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ScarfColor.warning.opacity(0.14))
    }
}
