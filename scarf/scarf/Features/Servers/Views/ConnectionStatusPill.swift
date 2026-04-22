import SwiftUI
import ScarfCore

/// Small colored pill shown in the toolbar reflecting the server's reach-
/// ability. Green = connected, yellow = probing, red = unreachable.
///
/// Clicking the pill (when red) surfaces the raw stderr so users can
/// diagnose SSH issues without digging through Console.
struct ConnectionStatusPill: View {
    let status: ConnectionStatusViewModel
    @State private var showDetails = false
    @State private var showDiagnostics = false

    var body: some View {
        Button {
            switch status.status {
            case .error:
                showDetails = true
            case .degraded:
                // Yellow "can't read" state — open the diagnostics sheet
                // so the user can see exactly which files fail and why.
                showDiagnostics = true
            case .connected, .idle:
                status.retry()
            }
        } label: {
            // Leading SF Symbol does double duty: its color is the status
            // signal (green/orange/yellow/red), and its shape reads as a
            // clickable toolbar tool. No custom background — the toolbar's
            // `.principal` emphasis bezel is the frame.
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .foregroundStyle(color)
                    .symbolRenderingMode(.hierarchical)
                labelText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            errorDetails.frame(width: 400)
        }
        .sheet(isPresented: $showDiagnostics) {
            RemoteDiagnosticsView(context: status.context)
        }
    }

    private var color: Color {
        switch status.status {
        case .connected: return .green
        case .degraded: return .orange
        case .idle: return .yellow
        case .error: return .red
        }
    }

    /// State-specific SF Symbol. The icon shape itself signals what the
    /// click will do: checkmark for connected (click to re-probe),
    /// stethoscope for degraded (click to run diagnostics), spinning
    /// arrows for probing, triangle for error.
    private var iconName: String {
        switch status.status {
        case .connected: return "checkmark.circle.fill"
        case .degraded: return "stethoscope"
        case .idle: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var labelText: Text {
        switch status.status {
        case .connected: return Text("Connected")
        case .degraded: return Text("Connected — can't read Hermes state")
        case .idle: return Text("Checking…")
        case .error(let message, _): return Text(verbatim: message)
        }
    }

    private var tooltipText: Text {
        switch status.status {
        case .connected:
            if let ts = status.lastSuccess {
                let fmt = RelativeDateTimeFormatter()
                return Text("Last probe: \(fmt.localizedString(for: ts, relativeTo: Date()))")
            }
            return Text("Connected")
        case .degraded(let reason):
            return Text("SSH works but \(reason). Click for diagnostics.")
        case .idle: return Text("Waiting for first probe")
        case .error: return Text("Click for details")
        }
    }

    @ViewBuilder
    private var errorDetails: some View {
        if case .error(let message, let stderr) = status.status {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    Spacer()
                    Button("Retry") {
                        status.retry()
                        showDetails = false
                    }
                }
                Divider()

                // Specific guidance based on stderr classification.
                if stderr.isEmpty {
                    Text("No additional output. Check ~/.ssh/config and ssh-agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(stderr)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }

                // Tailored hint per failure class. We avoid auto-running
                // anything (Scarf can't safely invoke ssh-add or ssh-keygen
                // on the user's behalf), but copy-paste commands so the fix
                // is one paste away in Terminal.
                hintFor(stderr: stderr)
            }
            .padding(14)
            .frame(width: 440)
        }
    }

    @ViewBuilder
    private func hintFor(stderr: String) -> some View {
        let lower = stderr.lowercased()
        if lower.contains("host key verification failed")
            || lower.contains("remote host identification has changed") {
            // Known-hosts mismatch: this is the "blocking alert with
            // fingerprints" Phase 4 calls for. We can't safely auto-trust
            // a new key, so we offer the exact remediation command.
            HostKeyMismatchHint(serverHost: extractHostHint(from: stderr))
        } else if lower.contains("permission denied")
            || (lower.contains("publickey") && lower.contains("denied")) {
            SshAddHint()
        } else {
            Text("If this is the first connection, ensure your key is loaded with `ssh-add` and that the remote accepts it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Pull the host out of an ssh stderr line like
    /// "Host key verification failed for 192.168.0.82". Best-effort — falls
    /// back to a placeholder when no match is found.
    private func extractHostHint(from stderr: String) -> String {
        // Look for "Offending ECDSA key in /Users/.../.ssh/known_hosts:5"
        // or "Host key verification failed." — neither of which directly
        // contains the host. We fall back to scanning for an IP-like or
        // hostname-like token in the trace.
        let pattern = #"(?:host|key for) ['\"]?([A-Za-z0-9._-]+)['\"]?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: stderr) {
            return String(stderr[range])
        }
        return "<your-host>"
    }
}

/// Specific remediation card for "host key verification failed" — the
/// blocking case where ssh refuses because the remote's fingerprint changed.
/// We never auto-accept; the user runs ssh-keygen -R themselves.
private struct HostKeyMismatchHint: View {
    let serverHost: String
    @State private var copied = false

    private var command: String { "ssh-keygen -R \(serverHost)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Host key changed", systemImage: "exclamationmark.shield")
                .font(.subheadline).bold()
                .foregroundStyle(.orange)
            Text("The remote's SSH fingerprint no longer matches what your `~/.ssh/known_hosts` file expected. This usually means the remote was reinstalled — or, less commonly, that someone is intercepting the connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("If you trust the change, remove the stale entry and reconnect:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Hint for "Permission denied" failures — almost always means ssh-agent
/// doesn't have the right key loaded. We can't run ssh-add for the user
/// (no UI to handle the passphrase prompt), but we provide the exact
/// command + a copy button.
private struct SshAddHint: View {
    @State private var copied = false
    private let command = "ssh-add ~/.ssh/id_ed25519"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Authentication uses ssh-agent", systemImage: "key.viewfinder")
                .font(.subheadline).bold()
                .foregroundStyle(.blue)
            Text("Scarf never prompts for passphrases. Add your key to ssh-agent in Terminal, then click Retry. If your key isn't `id_ed25519`, swap the path:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .buttonStyle(.borderless)
            }
            Text("To skip the passphrase prompt at every reboot, add `--apple-use-keychain` to cache it in macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
