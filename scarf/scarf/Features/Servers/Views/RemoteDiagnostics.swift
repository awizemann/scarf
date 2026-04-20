import SwiftUI
import AppKit

/// Per-server diagnostics sheet. Shown from Manage Servers and from the
/// Dashboard "Run Diagnostics…" button when `lastReadError` is set. Gives
/// the user a specific list of what does/doesn't work over SSH, with
/// targeted remediation hints for each failure.
///
/// Design principle: a failing check always shows both the raw detail the
/// remote shell produced AND a human-written hint. The raw detail lets us
/// triage bug reports; the hint unblocks the user without a round trip.
struct RemoteDiagnosticsView: View {
    let context: ServerContext
    @State private var viewModel: RemoteDiagnosticsViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ServerContext) {
        self.context = context
        _viewModel = State(initialValue: RemoteDiagnosticsViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            probeList
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await viewModel.run() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Remote Diagnostics — \(context.displayName)")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Re-run") { Task { await viewModel.run() } }
                        .controlSize(.small)
                }
            }
            HStack {
                if viewModel.isRunning {
                    Text("Running checks…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label(viewModel.summary, systemImage: viewModel.allPassed ? "checkmark.seal" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(viewModel.allPassed ? .green : .orange)
                }
                Spacer()
                if !viewModel.probes.isEmpty {
                    Button {
                        copyReportToClipboard()
                    } label: {
                        Label("Copy Full Report", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("Copy a plain-text summary of every check (passes and fails) — paste into GitHub issues so we can see everything at once.")
                }
            }
        }
        .padding(16)
    }

    private var probeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.probes.isEmpty && viewModel.isRunning {
                    Text("Running a single shell session on \(context.displayName) that exercises every path Scarf reads…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
                ForEach(viewModel.probes) { probe in
                    probeRow(probe)
                    if probe.id != viewModel.probes.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func probeRow(_ probe: RemoteDiagnosticsViewModel.Probe) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: probe.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(probe.passed ? .green : .red)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(probe.id.title)
                    .font(.body)
                if !probe.detail.isEmpty {
                    Text(probe.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !probe.passed, let hint = probe.id.failureHint {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Raw-output disclosure. Shown when EVERY probe fails, since
            // that's the signature of a script-quoting / transport-level
            // issue rather than a real remote problem. Hidden in the normal
            // case so it doesn't distract.
            if !viewModel.probes.isEmpty, viewModel.passingCount == 0 {
                DisclosureGroup("Raw remote output (for debugging)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("exit code: \(viewModel.rawExitCode)")
                            .font(.caption.monospaced())
                        if !viewModel.rawStdout.isEmpty {
                            Text("stdout:").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                Text(viewModel.rawStdout)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                        if !viewModel.rawStderr.isEmpty {
                            Text("stderr:").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                Text(viewModel.rawStderr)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption)
            }
            HStack {
                Text("Scarf runs these over a single SSH session that mirrors the shell your dashboard reads from, so a green row here means Scarf can actually read that file at runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func copyReportToClipboard() {
        var lines: [String] = []
        lines.append("Scarf remote diagnostics — \(context.displayName)")
        if case .ssh(let config) = context.kind {
            lines.append("Host: \(config.host)" + (config.user.map { " (user: \($0))" } ?? ""))
            if let rh = config.remoteHome { lines.append("Hermes home (override): \(rh)") }
        }
        lines.append("Ran at: \(viewModel.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?")")
        lines.append("Result: \(viewModel.summary)")
        lines.append("")
        for probe in viewModel.probes {
            let mark = probe.passed ? "PASS" : "FAIL"
            lines.append("[\(mark)] \(probe.id.title)")
            if !probe.detail.isEmpty { lines.append("    \(probe.detail)") }
            if !probe.passed, let hint = probe.id.failureHint {
                lines.append("    hint: \(hint)")
            }
        }
        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
