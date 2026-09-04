import SwiftUI
import ScarfCore
import ScarfDesign

/// Renders a markdown file from the project root through the same
/// `MarkdownContentView` pipeline used by the inline `text` widget. Picks
/// up edits automatically via the project-wide `.scarf/` directory watch
/// (v2.7).
struct MarkdownFileWidgetView: View {
    let widget: DashboardWidget

    @Environment(\.serverContext) private var serverContext
    @Environment(\.selectedProjectRoot) private var projectRoot
    @Environment(HermesFileWatcher.self) private var fileWatcher

    @State private var loadedContent: String?
    @State private var ioError: String?
    @State private var isLoading = false
    /// `path -> "<mtime>:<size>"` of the bytes currently rendered. A tick
    /// whose stat matches this reads nothing.
    @State private var loadedSignature: String?

    var body: some View {
        Group {
            switch WidgetPathResolver.resolve(widget.path, projectRoot: projectRoot) {
            case .failure(let err):
                WidgetErrorCard(
                    verbatimReason: err.userMessage,
                    title: widget.title,
                    hint: "Set `path` to a markdown file relative to the project root, e.g. `reports/weekly.md`."
                )
            case .success(let resolved):
                content(for: resolved)
                    .task(id: "\(resolved)|\(fileWatcher.lastChangeDate.timeIntervalSince1970)") {
                        await reload(absPath: resolved)
                    }
            }
        }
    }

    @ViewBuilder
    private func content(for absPath: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                    .scarfStyle(.caption)
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            if let ioError {
                Text(ioError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let loadedContent {
                MarkdownContentView(content: loadedContent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    private func reload(absPath: String) async {
        let context = serverContext
        isLoading = true
        defer { isLoading = false }
        let known = loadedSignature
        let hasContent = loadedContent != nil
        let outcome: (result: WidgetIOResult<String>?, signature: String?) = await Task.detached {
            let transport = context.makeTransport()
            // STAT FIRST. This view re-runs on every coalesced watcher tick
            // (`.task(id:)` is keyed on `lastChangeDate`), and the tick
            // fires per persisted message during a stream — so without this
            // the widget re-read and re-rendered its file several times a
            // second because something unrelated changed. One stat, then
            // nothing.
            let signature = WidgetFileRead.signature(absPath, transport: transport)
            if let signature, signature == known, hasContent { return (nil, signature) }
            // Measures disk/transport latency for reading the markdown file.
            let read = ScarfMon.measure(.diskIO, "widget.markdown_file.load") {
                WidgetFileRead.read(absPath, cap: WidgetFileRead.maxTextBytes, transport: transport)
            }
            switch read {
            case .failure(let err):
                return (.failure(err.message), signature)
            case .success(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    return (.failure("File is not UTF-8 — markdown_file expects text."), signature)
                }
                return (.success(text), signature)
            }
        }.value
        // GENERATION GUARD. `.task(id:)` cancels this body when the widget's
        // refresh key changes, but cancellation does NOT stop a suspended
        // `await` from resuming — and the detached read above does not
        // inherit cancellation at all. Without this check a slow read from an
        // earlier watcher tick resumed AFTER the newer one had already
        // committed, and overwrote it with older content.
        guard !Task.isCancelled else { return }
        // Nothing changed — leave the rendered content (and the
        // @State it lives in) exactly as it is.
        guard let result = outcome.result else { return }
        self.loadedSignature = outcome.signature
        switch result {
        case .success(let s):
            self.loadedContent = s
            self.ioError = nil
        case .failure(let err):
            self.loadedContent = nil
            self.ioError = err.message
        }
    }
}
