import SwiftUI
import ScarfCore

/// Entry screen for the Memory feature. Two rows: MEMORY.md and
/// USER.md. Each taps into `MemoryEditorView`. Pure SwiftUI — the
/// actual load/save happens in `IOSMemoryViewModel` which lives in
/// ScarfCore and is tested on Linux.
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
            } footer: {
                Text("These files live under `~/.hermes/memories/` on the remote host.")
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
