import SwiftUI
import ScarfCore
import ScarfDesign
import AppKit

/// Renders a local file (`path`, resolved relative to project root) or a
/// remote `url`. `path` wins when both are set. Local files refresh via the
/// project-wide `.scarf/` directory watch (v2.7); remote URLs are loaded
/// once per appearance and cached by the SwiftUI `AsyncImage` machinery.
struct ImageWidgetView: View {
    let widget: DashboardWidget

    @Environment(\.serverContext) private var serverContext
    @Environment(\.selectedProjectRoot) private var projectRoot
    @Environment(HermesFileWatcher.self) private var fileWatcher

    @State private var localImage: NSImage?
    @State private var loadError: String?

    private var displayHeight: CGFloat? {
        widget.height.map { CGFloat($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .scarfStyle(.caption)
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    @ViewBuilder
    private var content: some View {
        if let _ = widget.path {
            localContent
        } else if let url = widget.url, let parsed = URL(string: url) {
            remoteContent(url: parsed)
        } else {
            WidgetErrorCard(
                title: "",
                reason: "Image widget needs either `path` (local file relative to project root) or `url` (remote)."
            )
        }
    }

    @ViewBuilder
    private var localContent: some View {
        switch WidgetPathResolver.resolve(widget.path, projectRoot: projectRoot) {
        case .failure(let err):
            WidgetErrorCard(title: "", reason: err.userMessage)
        case .success(let resolved):
            Group {
                if let img = localImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: displayHeight)
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
                } else if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .task(id: "\(resolved)|\(fileWatcher.lastChangeDate.timeIntervalSince1970)") {
                await loadLocal(absPath: resolved)
            }
        }
    }

    private func remoteContent(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView().controlSize(.small)
            case .success(let img):
                img.resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: displayHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
            case .failure(let err):
                Text("Could not load image: \(err.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            @unknown default:
                EmptyView()
            }
        }
    }

    private func loadLocal(absPath: String) async {
        let context = serverContext
        let outcome: WidgetIOResult<NSImage> = await Task.detached {
            let transport = context.makeTransport()
            do {
                // Measures disk/transport latency for reading the image file.
                let data = try ScarfMon.measure(.diskIO, "widget.image.load") {
                    try transport.readFile(absPath)
                }
                if let img = NSImage(data: data) { return .success(img) }
                return .failure("File is not a recognized image format.")
            } catch {
                return .failure("Could not read file: \(error.localizedDescription)")
            }
        }.value
        // GENERATION GUARD — see `LogTailWidgetView.reload`. `.task(id:)`
        // cancellation does not stop a suspended `await` from resuming, and
        // the detached read does not inherit cancellation at all.
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let img):
            self.localImage = img
            self.loadError = nil
        case .failure(let err):
            self.localImage = nil
            self.loadError = err.message
        }
    }
}
