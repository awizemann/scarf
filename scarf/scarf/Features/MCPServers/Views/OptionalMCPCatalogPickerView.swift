import SwiftUI
import ScarfCore
import ScarfDesign

/// Minimal picker over Hermes's optional-MCP catalog roster (v0.20.4:
/// 20 entries, up from 6 — blender was removed). Selecting an entry hands
/// it back to `MCPServerAddCustomView`, which prefills name/transport/url/
/// auth; Scarf has no `hermes mcp install` equivalent, so this only saves
/// the user from retyping the well-known endpoint/name, not a full install.
struct OptionalMCPCatalogPickerView: View {
    let onSelect: (OptionalMCPCatalogEntry) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Optional MCP Catalog")
                    .scarfStyle(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
            }
            .padding()
            Divider()

            List(OptionalMCPCatalog.entries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.name)
                                .font(.system(.body, design: .monospaced).bold())
                            Text(entry.transport.id)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Text(entry.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 480, minHeight: 480)
    }
}
