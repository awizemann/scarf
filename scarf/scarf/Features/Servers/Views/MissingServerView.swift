import SwiftUI
import ScarfCore
import ScarfDesign

/// Shown when a window is restored after the user removed the server it
/// was bound to. Lets them open Local or any remaining registered server
/// in this same window without quitting + relaunching.
struct MissingServerView: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    let removedServerID: ServerID

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Server No Longer Exists")
                .font(.title2).bold()
            Text("The server this window was opened with has been removed from your registry.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Text("ID: \(removedServerID.uuidString)")
                .font(.caption)
                .monospaced()
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Open Local") {
                    openWindow(value: ServerContext.local.id)
                    dismissWindow()
                }
                .buttonStyle(ScarfPrimaryButton())

                if !registry.entries.isEmpty {
                    Menu {
                        ForEach(registry.entries) { entry in
                            Button(entry.displayName) {
                                openWindow(value: entry.id)
                                dismissWindow()
                            }
                        }
                    } label: {
                        Text("Open Other Server…")
                    }
                }

                Button("Close Window") { dismissWindow() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
