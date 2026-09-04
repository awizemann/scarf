import SwiftUI
import ScarfCore
import ScarfDesign

/// Compact pill in `SessionInfoBar` showing the active model preset.
/// Tap opens a popover with the full preset list — picking one fires
/// `onSwitch(preset)` (which the chat view model wires to ACP's
/// `session/set_model` RPC). "Use global default" is encoded as a nil
/// callback argument.
///
/// Capability-gated by the bar (`hasACPSetSessionModel`) so this view
/// never renders on hosts that can't actually switch.
struct ChatModelBadge: View {
    let preset: ModelPreset?
    let onSwitch: ((ModelPreset?) -> Void)?

    @State private var presets: [ModelPreset] = []
    @State private var isLoading = false
    @State private var showPopover = false
    @Environment(\.serverContext) private var serverContext

    var body: some View {
        Button {
            showPopover = true
            Task { await loadIfNeeded() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if onSwitch != nil {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .opacity(0.6)
                }
            }
            .scarfStyle(.caption)
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(ScarfColor.info.opacity(0.12)))
            .foregroundStyle(ScarfColor.info)
        }
        .buttonStyle(.plain)
        .disabled(onSwitch == nil)
        .help(helpText)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
                .frame(minWidth: 280, maxWidth: 340)
        }
    }

    private var label: String {
        if let preset {
            return preset.name
        }
        return "Default"
    }

    private var helpText: String {
        if let preset {
            return "Active model: \(preset.providerID) / \(preset.modelID)"
        }
        return "Running on config.yaml default. Click to pick a preset."
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Switch model")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(ScarfSpace.s2)
            Divider()

            if presets.isEmpty && !isLoading {
                VStack(spacing: ScarfSpace.s2) {
                    Text("No saved presets")
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Text("Create one in the Models sidebar to switch on the fly.")
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(ScarfSpace.s3)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        defaultRow
                        Divider()
                        ForEach(presets) { p in
                            presetRow(p)
                            if p.id != presets.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .background(ScarfColor.backgroundSecondary)
    }

    private var defaultRow: some View {
        Button {
            onSwitch?(nil)
            showPopover = false
        } label: {
            HStack {
                Image(systemName: preset == nil ? "checkmark" : "")
                    .frame(width: 16)
                    .foregroundStyle(ScarfColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use global default")
                        .scarfStyle(.body)
                    Text("From ~/.hermes/config.yaml")
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
            }
            .padding(ScarfSpace.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presetRow(_ p: ModelPreset) -> some View {
        let isActive = preset?.id == p.id
        return Button {
            onSwitch?(p)
            showPopover = false
        } label: {
            HStack {
                Image(systemName: isActive ? "checkmark" : "")
                    .frame(width: 16)
                    .foregroundStyle(ScarfColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .scarfStyle(.body)
                    Text("\(p.providerID) / \(p.modelID)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                Spacer()
            }
            .padding(ScarfSpace.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadIfNeeded() async {
        guard !isLoading else { return }
        isLoading = true
        let service = ModelPresetService.shared(for: serverContext)
        if let loaded = try? await service.list() {
            self.presets = loaded
        }
        isLoading = false
    }
}
