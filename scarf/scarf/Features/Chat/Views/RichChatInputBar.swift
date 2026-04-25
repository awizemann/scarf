import SwiftUI
import ScarfCore
import ScarfDesign

struct RichChatInputBar: View {
    let onSend: (String) -> Void
    let isEnabled: Bool
    var commands: [HermesSlashCommand] = []
    var showCompressButton: Bool = false

    @State private var text = ""
    @State private var showCompressSheet = false
    @State private var compressFocus = ""
    @State private var showMenu = false
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showMenu {
                SlashCommandMenu(
                    commands: filteredCommands,
                    agentHasCommands: !commands.isEmpty,
                    selectedIndex: $selectedIndex,
                    onSelect: insertCommand
                )
                .id(menuQuery)
                .background(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: ScarfSpace.s2) {
                if showCompressButton {
                    Button {
                        compressFocus = ""
                        showCompressSheet = true
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 16))
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .help("Compress conversation (/compress)")
                }

                TextEditor(text: $text)
                    .font(ScarfFont.body)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(minHeight: 28, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                            .fill(ScarfColor.backgroundSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: ScarfRadius.xl, style: .continuous)
                                    .strokeBorder(showMenu ? ScarfColor.accent : ScarfColor.borderStrong, lineWidth: 1)
                            )
                    )
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Message Hermes…  /  for commands")
                                .scarfStyle(.body)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        guard showMenu, !filteredCommands.isEmpty else { return .ignored }
                        let n = filteredCommands.count
                        selectedIndex = (selectedIndex - 1 + n) % n
                        return .handled
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        guard showMenu, !filteredCommands.isEmpty else { return .ignored }
                        let n = filteredCommands.count
                        selectedIndex = (selectedIndex + 1) % n
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        guard showMenu,
                              let command = filteredCommands[safe: selectedIndex] else { return .ignored }
                        insertCommand(command)
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        guard showMenu else { return .ignored }
                        showMenu = false
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        if showMenu, let command = filteredCommands[safe: selectedIndex] {
                            insertCommand(command)
                            return .handled
                        }
                        send()
                        return .handled
                    }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? ScarfColor.onAccent : ScarfColor.foregroundFaint)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .fill(canSend ? ScarfColor.accent : ScarfColor.backgroundSecondary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send message (Enter)")
            }
            .padding(.horizontal, ScarfSpace.s3)
            .padding(.vertical, ScarfSpace.s2)
        }
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .top
        )
        .onChange(of: text) { _, _ in
            updateMenuState()
        }
        .onChange(of: commands.map(\.id)) { _, _ in
            updateMenuState()
        }
        .sheet(isPresented: $showCompressSheet) {
            compressSheet
        }
    }

    private var compressSheet: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Compress Conversation")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text("Optionally focus the summary on a specific topic. Leave blank to compress evenly.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            ScarfTextField("Focus topic (optional)", text: $compressFocus)
            HStack {
                Spacer()
                Button("Cancel") { showCompressSheet = false }
                    .buttonStyle(ScarfGhostButton())
                Button("Compress") {
                    let focus = compressFocus.trimmingCharacters(in: .whitespacesAndNewlines)
                    let command = focus.isEmpty ? "/compress" : "/compress \(focus)"
                    onSend(command)
                    showCompressSheet = false
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 380)
    }

    private var canSend: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Show the slash menu only while the user is typing the command token:
    /// text starts with `/` and contains no whitespace (space or newline).
    private var shouldShowMenu: Bool {
        guard text.hasPrefix("/") else { return false }
        return !text.contains(" ") && !text.contains("\n")
    }

    private var menuQuery: String {
        guard text.hasPrefix("/") else { return "" }
        return String(text.dropFirst())
    }

    private var filteredCommands: [HermesSlashCommand] {
        SlashCommandMenu.filter(commands: commands, query: menuQuery)
    }

    private func updateMenuState() {
        let shouldShow = shouldShowMenu
        if shouldShow != showMenu {
            showMenu = shouldShow
        }
        // Re-clamp selection whenever the filtered list may have shrunk.
        let count = filteredCommands.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }

    private func insertCommand(_ command: HermesSlashCommand) {
        if command.argumentHint != nil {
            text = "/\(command.name) "
        } else {
            text = "/\(command.name)"
        }
        showMenu = false
        selectedIndex = 0
        isFocused = true
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isEnabled else { return }
        onSend(trimmed)
        text = ""
        showMenu = false
        selectedIndex = 0
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
