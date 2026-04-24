import SwiftUI
import ScarfCore

/// Entry screen for the Memory feature. Three rows: MEMORY.md,
/// USER.md, and SOUL.md (persona). SOUL lives in the Personalities
/// feature on macOS; we fold it in here on iOS so the whole
/// "agent prompt inputs" surface is one tap away. Each row taps into
/// `MemoryEditorView`. Pure SwiftUI — the actual load/save happens in
/// `IOSMemoryViewModel` which lives in ScarfCore.
struct MemoryListView: View {
    let config: IOSServerConfig

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    var body: some View {
        let ctx = config.toServerContext(id: Self.sharedContextID)
        List {
            Section {
                memoryRow(.memory, context: ctx)
                memoryRow(.user, context: ctx)
                memoryRow(.soul, context: ctx)
            } footer: {
                Text("MEMORY.md and USER.md live under `~/.hermes/memories/`. SOUL.md lives at `~/.hermes/SOUL.md`.")
                    .font(.caption)
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func memoryRow(_ kind: IOSMemoryViewModel.Kind, context: ServerContext) -> some View {
        NavigationLink {
            MemoryEditorView(kind: kind, context: context)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: kind.iconName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
