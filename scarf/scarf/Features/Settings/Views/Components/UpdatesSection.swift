import SwiftUI

/// Updates section for the General tab. Wraps the Sparkle-backed `UpdaterService`
/// in the same row idioms used elsewhere in Settings (per CLAUDE.md guidance —
/// extract sections so individual tab bodies stay small).
struct UpdatesSection: View {
    @Environment(UpdaterService.self) private var updater

    var body: some View {
        SettingsSection(title: "Updates", icon: "arrow.down.circle") {
            ReadOnlyRow(label: "Current Version", value: versionString)
            ToggleRow(
                label: "Check Automatically",
                isOn: updater.automaticallyChecksForUpdates
            ) { newValue in
                updater.automaticallyChecksForUpdates = newValue
            }
            ReadOnlyRow(label: "Last Checked", value: lastCheckedString)
            checkNowRow
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var lastCheckedString: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var checkNowRow: some View {
        HStack {
            Text("Check Now")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .trailing)
            Button("Check for Updates…") { updater.checkForUpdates() }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}
