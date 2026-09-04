import SwiftUI
import ScarfCore
import ScarfDesign

/// Tails the last N lines of a file under the project root, monospaced.
/// Best paired with cron jobs that write atomically (write-temp + rename)
/// — the project-wide `.scarf/` directory watch (v2.7) refreshes the
/// widget when a new file lands. In-place appends to an existing file
/// won't tick `lastChangeDate`; the cron job should `touch dashboard.json`
/// after each run if it appends in place.
struct LogTailWidgetView: View {
    let widget: DashboardWidget

    @Environment(\.serverContext) private var serverContext
    @Environment(\.selectedProjectRoot) private var projectRoot
    @Environment(HermesFileWatcher.self) private var fileWatcher

    @State private var loadedTail: String?
    @State private var loadError: WidgetPathResolver.ResolveError?
    @State private var ioError: String?
    @State private var isLoading = false

    private var lineCount: Int { max(1, min(200, widget.lines ?? 20)) }

    var body: some View {
        Group {
            switch WidgetPathResolver.resolve(widget.path, projectRoot: projectRoot) {
            case .failure(let err):
                WidgetErrorCard(
                    verbatimReason: err.userMessage,
                    title: widget.title,
                    hint: "Set `path` to a file relative to the project root, e.g. `reports/uptime.log`."
                )
            case .success(let resolved):
                content(for: resolved)
                    .task(id: refreshKey(resolved)) {
                        await reload(absPath: resolved)
                    }
            }
        }
    }

    private func refreshKey(_ resolved: String) -> String {
        // Force a reload whenever either the widget config or any project
        // file changes (the latter via fileWatcher.lastChangeDate).
        "\(resolved)|\(lineCount)|\(fileWatcher.lastChangeDate.timeIntervalSince1970)"
    }

    @ViewBuilder
    private func content(for absPath: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.below.ecg")
                    .foregroundStyle(.secondary)
                    .scarfStyle(.caption)
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("last \(lineCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            if let ioError {
                Text(ioError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let loadedTail {
                tailBody(loadedTail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    @ViewBuilder
    private func tailBody(_ tail: String) -> some View {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.isEmpty {
            Text("(empty)").font(.caption2).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Each line stays visually truncated (tail is a
                        // dense monospaced view), but its accessibility
                        // text carries the whole line, untruncated.
                        .accessibilityLabel(Text(String(line)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
            // Twenty separate one-line VO stops per widget were a wall to
            // walk through. Group into one element with the full tail as
            // its value, so a single VO stop gives the whole content;
            // reading line-by-line is still possible via the rotor into
            // the child Texts if needed, since .contain (not .combine)
            // keeps them addressable.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Log tail"))
            .accessibilityValue(Text(tail))
        }
    }

    private func reload(absPath: String) async {
        let context = serverContext
        let n = lineCount
        isLoading = true
        defer { isLoading = false }
        let outcome: WidgetIOResult<String> = await Task.detached {
            let transport = context.makeTransport()
            do {
                // BOUNDED. This widget shows the last `n` lines of a log, and
                // it used to pull the WHOLE file across the transport to get
                // them — on a dashboard that reloads on every watcher tick,
                // against a log that grows all day. `tail -n` does the
                // bounding at the source on both local and remote transports
                // (the same tool `HermesLogService` uses for its remote
                // branch), so the transfer is proportional to what is shown.
                let text: String = try ScarfMon.measure(.diskIO, "widget.log_tail.load") {
                    if let result = try? transport.runProcess(
                        executable: "/usr/bin/tail",
                        args: ["-n", String(n), absPath],
                        stdin: nil,
                        timeout: 30
                    ), result.exitCode == 0 {
                        return result.stdoutString
                    }
                    // `tail` absent or refused (an unusual host, or a path it
                    // can't stat): fall back to the whole-file read rather
                    // than showing nothing. Correctness over the optimisation.
                    let data = try transport.readFile(absPath)
                    guard let whole = String(data: data, encoding: .utf8) else {
                        throw WidgetTailError.notUTF8
                    }
                    return whole
                }
                let stripped = AnsiStripper.strip(text)
                let parts = stripped.split(separator: "\n", omittingEmptySubsequences: false)
                return .success(parts.suffix(n).joined(separator: "\n"))
            } catch is WidgetTailError {
                return .failure("File is not UTF-8 — log_tail expects text.")
            } catch {
                return .failure("Could not read file: \(error.localizedDescription)")
            }
        }.value
        // GENERATION GUARD. `.task(id:)` cancels this body when the widget's
        // refresh key changes, but cancellation does NOT stop a suspended
        // `await` from resuming — and the detached read above does not
        // inherit cancellation at all. Without this check a slow read from an
        // earlier watcher tick resumed AFTER the newer one had already
        // committed, and overwrote it with older content.
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let s):
            self.loadedTail = s
            self.ioError = nil
        case .failure(let err):
            self.loadedTail = nil
            self.ioError = err.message
        }
    }
}

/// Local sentinel so the non-UTF-8 case can travel out of the measured
/// closure as a `throw` rather than as a second return channel.
private enum WidgetTailError: Error { case notUTF8 }
