import SwiftUI
import ScarfCore
import ScarfDesign
import AppKit

/// Mac equivalent of the iOS Diagnostics → Performance panel. Embedded
/// inside the Settings → Advanced tab so users investigating sluggish
/// behavior can flip ScarfMon to Full mode, watch live aggregated
/// stats, and copy the ring-buffer JSON for a feedback thread.
///
/// The panel is process-wide — `ScarfMonBoot.sharedRingBuffer` is the
/// same instance the iOS panel reads. On Mac we use NSPasteboard
/// instead of UIPasteboard, otherwise the UI is the same shape.
struct ScarfMonDiagnosticsSection: View {
    @State private var mode: ScarfMonBoot.Mode = ScarfMonBoot.currentMode()
    @State private var stats: [ScarfMonStat] = []
    @State private var copiedToast: Bool = false

    private let refreshInterval: TimeInterval = 1.0

    var body: some View {
        SettingsSection(title: "Performance Diagnostics", icon: "speedometer") {
            VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                modeRow
                Text("Default mode emits Instruments signposts only — no measurable cost outside an active profiling session. Switch to Full to keep an in-memory ring buffer (4096 entries) you can inspect below or copy as JSON.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                if mode == .full {
                    Divider()
                    summaryGrid
                    HStack {
                        Button("Copy as JSON") { copyJSON() }
                        Button("Reset", role: .destructive) {
                            ScarfMonBoot.sharedRingBuffer?.reset()
                            refresh()
                        }
                        if copiedToast {
                            Text("Copied")
                                .scarfStyle(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: mode) {
            guard mode == .full else { return }
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
            }
        }
    }

    @ViewBuilder
    private var modeRow: some View {
        HStack {
            Text("Mode")
                .frame(width: 80, alignment: .leading)
            Picker("Mode", selection: $mode) {
                Text("Off").tag(ScarfMonBoot.Mode.off)
                Text("Signpost only").tag(ScarfMonBoot.Mode.signpostOnly)
                Text("Full").tag(ScarfMonBoot.Mode.full)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, newValue in
                AppScarfMonBoot.setMode(newValue)
            }
        }
    }

    @ViewBuilder
    private var summaryGrid: some View {
        if stats.isEmpty {
            Text("No samples yet. Use the app for a few seconds.")
                .scarfStyle(.footnote)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(stats.prefix(20), id: \.self) { stat in
                    statRow(stat)
                }
            }
        }
    }

    @ViewBuilder
    private func statRow(_ stat: ScarfMonStat) -> some View {
        HStack(spacing: ScarfSpace.s3) {
            Text(stat.category.rawValue)
                .scarfStyle(.mono)
                .foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .leading)
            Text(stat.name)
                .scarfStyle(.mono)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("count \(stat.count)")
                .scarfStyle(.mono)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            if stat.kind == .interval {
                Text("p50 \(formatMs(stat.p50Ms))")
                    .scarfStyle(.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                Text("p95 \(formatMs(stat.p95Ms))")
                    .scarfStyle(.mono)
                    .foregroundStyle(.primary)
                    .frame(width: 90, alignment: .trailing)
                Text("max \(formatMs(stat.maxMs))")
                    .scarfStyle(.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            } else if stat.totalBytes > 0 {
                Text("bytes \(stat.totalBytes)")
                    .scarfStyle(.mono)
                    .foregroundStyle(.secondary)
                    .frame(width: 270, alignment: .trailing)
            }
        }
    }

    private func refresh() {
        stats = ScarfMonBoot.sharedRingBuffer?.summary() ?? []
    }

    private func copyJSON() {
        guard let json = ScarfMonBoot.sharedRingBuffer?.exportJSON() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
        copiedToast = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedToast = false
        }
    }

    private func formatMs(_ ms: Double) -> String {
        if ms >= 100 { return String(format: "%.0fms", ms) }
        if ms >= 1   { return String(format: "%.1fms", ms) }
        return String(format: "%.2fms", ms)
    }
}
