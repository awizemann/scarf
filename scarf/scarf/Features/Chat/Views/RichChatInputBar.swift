import SwiftUI
import ScarfCore
import ScarfDesign
import UniformTypeIdentifiers
import os
#if canImport(AppKit)
import AppKit
#endif

struct RichChatInputBar: View {
    /// Send the user's text and any attached images. Empty `images`
    /// preserves the v0.11 wire shape; non-empty images are forwarded
    /// as ACP image content blocks (Hermes v0.12+; the composer hides
    /// the attachment UI on older hosts).
    let onSend: (String, [ChatImageAttachment]) -> Void
    let isEnabled: Bool
    var commands: [HermesSlashCommand] = []
    var showCompressButton: Bool = false

    @Environment(\.hermesCapabilities) private var capabilitiesStore

    @State private var text = ""
    @State private var showCompressSheet = false
    @State private var compressFocus = ""
    @State private var showMenu = false
    @State private var selectedIndex = 0
    @State private var attachments: [ChatImageAttachment] = []
    /// True while ImageEncoder is decoding/encoding pasted/dropped bytes.
    /// Renders a small spinner in the preview strip so the user knows
    /// their drop landed.
    @State private var isEncodingAttachment = false
    /// User-visible failure (decode failed, format unsupported). Auto-clears.
    @State private var attachmentError: String?
    @FocusState private var isFocused: Bool

    /// Hard cap matches what Hermes' vision aux model swallows comfortably
    /// in one prompt. Going higher costs tokens without a quality gain.
    private static let maxAttachments = 5

    private static let logger = Logger(subsystem: "com.scarf", category: "ChatComposer")

    /// `nil` until detection finishes — we hide the attachment UI in
    /// that brief window (~50ms locally, longer over SSH) so we never
    /// flash an attachment chip a v0.11 host couldn't honor.
    private var supportsImagePrompts: Bool {
        capabilitiesStore?.capabilities.hasACPImagePrompts ?? false
    }

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

            if !attachments.isEmpty || isEncodingAttachment || attachmentError != nil {
                attachmentStrip
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

                if supportsImagePrompts {
                    attachmentButton
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
                        // Placeholder ghosting (#65): TextEditor's
                        // NSTextView updates the visible glyphs a frame
                        // before the SwiftUI binding propagates, so a
                        // bare `if text.isEmpty` overlay renders the
                        // translucent placeholder text on top of the
                        // just-typed character — visible as a "behind
                        // or around" ghost. Three mitigations:
                        //
                        //   1. Pin an opaque rectangle behind the
                        //      placeholder text. During any single-
                        //      frame lag the user sees a clean
                        //      placeholder, never layered glyphs.
                        //   2. Use `.opacity(...)` instead of an `if`.
                        //      Keeps the view tree stable per
                        //      keystroke (removes the per-keystroke
                        //      view-mutation churn the composer was
                        //      already paying for).
                        //   3. Constrain to a single line with
                        //      `frame(maxWidth: .infinity)` and
                        //      `truncationMode(.tail)` so the long-form
                        //      hint can't escape the rounded
                        //      TextEditor bounds when the sidebar /
                        //      detail-pane geometry compresses the
                        //      composer (was visibly overflowing).
                        Text(supportsImagePrompts
                             ? "Message Hermes…  /  for commands · drag images to attach"
                             : "Message Hermes…  /  for commands")
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(ScarfColor.backgroundSecondary)
                            // Hide once the field has any content OR
                            // the user is actively focused — matches
                            // standard NSTextField / UITextField
                            // placeholder semantics.
                            .opacity((text.isEmpty && !isFocused) ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    // Drag-drop image attachments. Receives both file URLs
                    // (from Finder) and raw image bitmap data (from
                    // screenshot tools that drop tiff/png directly).
                    // Capability-gated so v0.11 hosts don't surface a
                    // drop target that does nothing.
                    .onDrop(
                        of: supportsImagePrompts ? [.image, .fileURL] : [],
                        isTargeted: nil
                    ) { providers in
                        guard supportsImagePrompts else { return false }
                        ingestProviders(providers)
                        return true
                    }
                    // Paste from screenshots / browser context menu.
                    // Accepting `Data` keeps us off `NSImage` which would
                    // require AppKit-typed paste. v0.12+ only.
                    .onPasteCommand(of: pasteAcceptedTypes) { providers in
                        ingestProviders(providers)
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
        // Watch `commands.count` rather than `commands.map(\.id)` — the
        // mapped form allocates a fresh `[String]` on every body
        // re-eval (i.e. every keystroke), which is wasted work even
        // when the array compares equal. The count proxy fires when
        // the agent advertises new commands.
        .onChange(of: commands.count) { _, _ in
            updateMenuState()
        }
        .sheet(isPresented: $showCompressSheet) {
            compressSheet
        }
    }

    /// Horizontal preview strip for attached images. Each chip shows the
    /// thumbnail (or a placeholder icon if we couldn't render one) plus
    /// an X to remove the attachment.
    @ViewBuilder
    private var attachmentStrip: some View {
        HStack(alignment: .center, spacing: ScarfSpace.s2) {
            if isEncodingAttachment {
                ProgressView()
                    .controlSize(.small)
                Text("Encoding…")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            ForEach(attachments) { attachment in
                attachmentChip(attachment)
            }
            if let err = attachmentError {
                Text(err)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.danger)
            }
            Spacer(minLength: 0)
            if !attachments.isEmpty {
                Text("\(attachments.count)/\(Self.maxAttachments)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.top, ScarfSpace.s2)
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: ChatImageAttachment) -> some View {
        let thumb = chipThumbnail(for: attachment)
        HStack(spacing: 4) {
            thumb
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .buttonStyle(.plain)
            .help(attachment.filename ?? "Image attachment")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md)
                .fill(ScarfColor.backgroundTertiary)
        )
    }

    /// Render the inline thumbnail for a chip. Falls back to a generic
    /// photo icon when the encoder didn't produce a thumbnail (e.g. the
    /// image was already small enough to skip the resize step).
    @ViewBuilder
    private func chipThumbnail(for attachment: ChatImageAttachment) -> some View {
        if let thumb = attachment.thumbnailBase64,
           let data = Data(base64Encoded: thumb),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ScarfColor.backgroundSecondary)
        }
    }

    private var attachmentButton: some View {
        Button {
            presentImagePicker()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 16))
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(6)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || attachments.count >= Self.maxAttachments)
        .help("Attach image (\(attachments.count)/\(Self.maxAttachments))")
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
                    onSend(command, [])
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
        guard isEnabled else { return false }
        // Allow sending image-only messages once at least one attachment
        // exists — vision models accept "describe this" with no text.
        if !attachments.isEmpty { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// MIME types accepted for paste. Restricting to image-bearing
    /// providers stops macOS from offering a paste menu when the user
    /// has plain text on the clipboard.
    private var pasteAcceptedTypes: [UTType] {
        supportsImagePrompts ? [.image, .png, .jpeg, .tiff, .heic] : []
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

        // Common case: user is composing normal text and the menu is
        // already hidden. Skip the filter computation + state writes
        // entirely so onChange stays cheap. Without this guard typing
        // recomputes `filteredCommands` on every keystroke even when
        // the menu can't possibly appear.
        guard shouldShow || showMenu else { return }

        // Compute desired selection, then only write what changed.
        // SwiftUI emits "onChange action tried to update multiple
        // times per frame" when an onChange handler mutates more than
        // one piece of state per frame; the warning correlates with
        // unusable typing lag because each redundant write triggers
        // another body re-eval.
        let count = filteredCommands.count
        let newSelection: Int
        if count == 0 {
            newSelection = 0
        } else if selectedIndex >= count {
            newSelection = count - 1
        } else if selectedIndex < 0 {
            newSelection = 0
        } else {
            newSelection = selectedIndex
        }

        if shouldShow != showMenu {
            showMenu = shouldShow
        }
        if newSelection != selectedIndex {
            selectedIndex = newSelection
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
        guard canSend else { return }
        onSend(trimmed, attachments)
        text = ""
        attachments.removeAll()
        showMenu = false
        selectedIndex = 0
    }

    // MARK: - Attachment ingestion

    /// Pull image bytes out of a set of `NSItemProvider`s (drag/drop or
    /// paste). Each provider may carry a file URL OR raw image data —
    /// we try both. Caps at `maxAttachments`; surplus drops are
    /// dropped silently with a status message.
    private func ingestProviders(_ providers: [NSItemProvider]) {
        let remainingSlots = Self.maxAttachments - attachments.count
        guard remainingSlots > 0 else {
            attachmentError = "Limit of \(Self.maxAttachments) images reached"
            scheduleAttachmentErrorClear()
            return
        }
        let toIngest = providers.prefix(remainingSlots)
        for provider in toIngest {
            ingestProvider(provider)
        }
    }

    private func ingestProvider(_ provider: NSItemProvider) {
        // Prefer file URL when available — gives us the original filename
        // for the attachment chip's tooltip.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            isEncodingAttachment = true
            provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    Task { @MainActor in
                        isEncodingAttachment = false
                        attachmentError = "Couldn't read dropped file"
                        scheduleAttachmentErrorClear()
                    }
                    return
                }
                encode(data: data, filename: url.lastPathComponent)
            }
            return
        }
        for typeId in [UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.heic.identifier] {
            if provider.hasItemConformingToTypeIdentifier(typeId) {
                isEncodingAttachment = true
                provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                    guard let data else {
                        Task { @MainActor in
                            isEncodingAttachment = false
                            attachmentError = "Couldn't decode pasted image"
                            scheduleAttachmentErrorClear()
                        }
                        return
                    }
                    encode(data: data, filename: nil)
                }
                return
            }
        }
    }

    private func encode(data: Data, filename: String?) {
        Task.detached(priority: .userInitiated) {
            do {
                let attachment = try ImageEncoder().encode(rawBytes: data, sourceFilename: filename)
                await MainActor.run {
                    isEncodingAttachment = false
                    attachments.append(attachment)
                }
            } catch {
                await MainActor.run {
                    isEncodingAttachment = false
                    attachmentError = (error as? LocalizedError)?.errorDescription ?? "Couldn't encode image"
                    Self.logger.warning("ImageEncoder failed: \(error.localizedDescription, privacy: .public)")
                    scheduleAttachmentErrorClear()
                }
            }
        }
    }

    private func scheduleAttachmentErrorClear() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            attachmentError = nil
        }
    }

    private func presentImagePicker() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .heic]
        panel.message = "Choose images to attach"
        panel.prompt = "Attach"
        let response = panel.runModal()
        guard response == .OK else { return }
        let urls = Array(panel.urls.prefix(Self.maxAttachments - attachments.count))
        guard !urls.isEmpty else { return }
        isEncodingAttachment = true
        Task.detached(priority: .userInitiated) {
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                encode(data: data, filename: url.lastPathComponent)
            }
        }
        #endif
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
