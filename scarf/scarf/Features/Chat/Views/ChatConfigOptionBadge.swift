import SwiftUI
import ScarfCore
import ScarfDesign

/// Header chip for one gateway-backed ACP config option — reasoning effort
/// (Hermes v0.22.6+) or service tier (v0.23.0+). Everything it shows comes
/// from the option Hermes advertised in `configOptions`
/// (acp_adapter/gateway_session_meta.py:83-125 @ v0.23.0): its name, its
/// rows (including `default` only while no level is set, and an
/// "(unavailable on this route)" tier row) and the current value. No list
/// is hardcoded here; `SessionInfoBar` renders it only for
/// `ACPConfigOption.visiblePickers`.
struct ChatConfigOptionBadge: View {
    let option: ACPConfigOption
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Section(option.name) {
                ForEach(option.choices, id: \.value) { choice in
                    Button {
                        if choice.value != option.currentValue { onSelect(choice.value) }
                    } label: {
                        if choice.value == option.currentValue {
                            Label(choice.name, systemImage: "checkmark")
                        } else {
                            Text(choice.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .opacity(0.6)
            }
            .scarfStyle(.caption)
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(ScarfBadgeKind.info.tinted(0.12)))
            .foregroundStyle(ScarfBadgeKind.info.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(option.name): \(label)")
    }

    private var label: String {
        option.currentChoice?.name ?? option.currentValue ?? option.name
    }

    private var icon: String {
        switch option.id {
        case ACPConfigOption.reasoningEffortId: return "brain"
        case ACPConfigOption.serviceTierId: return "hare"
        default: return "slider.horizontal.3"
        }
    }
}
