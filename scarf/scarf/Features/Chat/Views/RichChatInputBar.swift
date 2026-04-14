import SwiftUI

struct RichChatInputBar: View {
    let onSend: (String) -> Void
    let isEnabled: Bool
    var supportsCompress: Bool = false

    @State private var text = ""
    @State private var showCompressSheet = false
    @State private var compressFocus = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if supportsCompress {
                Button {
                    compressFocus = ""
                    showCompressSheet = true
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .help("Compress conversation (/compress)")
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 28, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message Hermes...")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    send()
                    return .handled
                }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send message (Enter)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showCompressSheet) {
            compressSheet
        }
    }

    private var compressSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compress Conversation")
                .font(.headline)
            Text("Optionally focus the summary on a specific topic. Leave blank to compress evenly.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Focus topic (optional)", text: $compressFocus)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showCompressSheet = false }
                Button("Compress") {
                    let focus = compressFocus.trimmingCharacters(in: .whitespacesAndNewlines)
                    let command = focus.isEmpty ? "/compress" : "/compress \(focus)"
                    onSend(command)
                    showCompressSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var canSend: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isEnabled else { return }
        onSend(trimmed)
        text = ""
    }
}
