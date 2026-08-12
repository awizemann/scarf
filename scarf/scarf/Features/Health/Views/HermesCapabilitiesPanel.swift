import SwiftUI
import ScarfCore
import ScarfDesign

/// Diagnostic strip for the per-window `HermesCapabilitiesStore`. Shows
/// the raw `hermes --version` line, the parsed semver + date version,
/// and a count of active capability flags. Drives Scarf's branching UI
/// (slash menu, Kanban surface, model presets, etc.), so when the
/// strip says "Not detected" the user instantly sees why the rest of
/// the app looks sparse.
///
/// Why this exists: detection runs once on store init via
/// `hermes --version`. If that subprocess fails silently or the parse
/// returns `.empty`, every capability-gated UI surface goes dark — and
/// before this strip there was no in-app surface that revealed the
/// gate was the cause. P1 of the projects-feature fix.
struct HermesCapabilitiesPanel: View {
    let store: HermesCapabilitiesStore?

    @State private var isReDetecting = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack(spacing: ScarfSpace.s2) {
                statusDot
                summaryText
                Spacer()
                Button {
                    Task { await reDetect() }
                } label: {
                    if isReDetecting {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Detecting…")
                        }
                    } else {
                        Text("Re-detect")
                    }
                }
                .buttonStyle(ScarfGhostButton())
                .disabled(isReDetecting || store == nil)
                .help("Re-run `hermes --version` and refresh the capability gate. " +
                      "Use after `hermes update` or installing a new Hermes binary.")
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide flag list" : "Show all active flags")
            }
            if isExpanded {
                Divider()
                flagList
            }
        }
        .padding(ScarfSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(borderColor.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Header pieces

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    @ViewBuilder
    private var summaryText: some View {
        if let store {
            if store.isLoading {
                Text("Detecting Hermes capabilities…")
                    .scarfStyle(.captionStrong)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
            } else if store.capabilities.detected {
                HStack(spacing: ScarfSpace.s2) {
                    Text(store.capabilities.versionLine)
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Text("· \(activeFlagCount) capabilities active")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    if store.isProvisional {
                        // Shown when this version came from the persisted
                        // last-known value rather than a probe that succeeded
                        // this session — the host may have changed since.
                        Text("· remembered (probe unavailable)")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.warning)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes version not detected")
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.danger)
                    Text("Capability-gated UI is hidden. Check that `hermes` is on PATH and `hermes --version` returns a recognizable line.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
        } else {
            Text("No capability store in environment.")
                .scarfStyle(.captionStrong)
                .foregroundStyle(ScarfColor.warning)
        }
    }

    // MARK: - Flag list

    @ViewBuilder
    private var flagList: some View {
        let caps = store?.capabilities ?? .empty
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            flagRow("v0.12 (Curator, Kanban, multimodal ACP)", on: caps.hasCurator)
            flagRow("v0.13 (Goals, ACP queue, model presets)", on: caps.isV013OrLater)
            flagRow("v0.14 (Subgoal, /yolo, /sessions, Proxy)", on: caps.isV014OrLater)
            flagRow("v0.15 (Kanban v0.15, ntfy, MCP mTLS, Bitwarden)", on: caps.isV015OrLater)
            if caps.detected {
                Divider().padding(.vertical, 2)
                Text("These flags drive the slash menu, project Kanban tab, model presets, and other version-gated surfaces. A red entry means UI for that release is hidden because the connected Hermes is older.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    @ViewBuilder
    private func flagRow(_ label: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(on ? ScarfColor.success : ScarfColor.foregroundFaint)
                .font(.system(size: 11))
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(on ? ScarfColor.foregroundPrimary : ScarfColor.foregroundFaint)
        }
    }

    // MARK: - Computed style

    private var dotColor: Color {
        guard let store else { return ScarfColor.warning }
        if store.isLoading { return ScarfColor.warning }
        return store.capabilities.detected ? ScarfColor.success : ScarfColor.danger
    }

    private var borderColor: Color {
        guard let store else { return ScarfColor.warning }
        if store.isLoading { return ScarfColor.foregroundFaint }
        return store.capabilities.detected ? ScarfColor.success : ScarfColor.danger
    }

    private var activeFlagCount: Int {
        guard let caps = store?.capabilities, caps.detected else { return 0 }
        var n = 0
        if caps.hasCurator { n += 1 }
        if caps.isV013OrLater { n += 1 }
        if caps.isV014OrLater { n += 1 }
        if caps.isV015OrLater { n += 1 }
        return n
    }

    // MARK: - Actions

    private func reDetect() async {
        guard let store, !isReDetecting else { return }
        isReDetecting = true
        await store.refresh()
        isReDetecting = false
    }
}
