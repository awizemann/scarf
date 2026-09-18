import Foundation

/// Model-only context attached to an ACP prompt as an `EmbeddedResource`
/// text block (`{"type":"resource","resource":{"uri","mimeType","text"}}`).
///
/// **Why this works — Hermes at tag v2026.9.14:**
/// - The persisted user row is `_extract_text(prompt)`, which joins only
///   blocks that have a `.text` attribute (`acp_adapter/content.py:224-226`);
///   an embedded-resource block has `.resource`, not `.text`, so the note is
///   never stored as the transcript, the auto-title or search text.
///   (`persist_user_message=user_text`, `acp_adapter/server.py:773-776`.)
/// - The model input is `_content_blocks_to_openai_user_content`
///   (`content.py:249-275`), which inlines `TextResourceContents` text via
///   `_embedded_resource_to_parts` (`:185-194`, `:265-266`) under an
///   "[Attached file: …]" header.
/// - Hermes does NOT advertise `promptCapabilities.embeddedContext`
///   (`server.py:517`, `image=True` only): this relies on tolerant parsing.
///   A contract test pins the wire shape; recheck it in every Hermes release
///   audit. See also the upstream request in
///   documents/plans/2026-09-18-hermes-acp-voice-surface-request.md.
public struct ACPContextNote: Sendable, Equatable {
    public let uri: String
    public let mimeType: String
    public let text: String

    public init(uri: String, text: String, mimeType: String = "text/plain") {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }

    /// The ACP content block.
    var contentBlock: [String: Any] {
        [
            "type": "resource",
            "resource": [
                "uri": uri,
                "mimeType": mimeType,
                "text": text,
            ] as [String: Any],
        ]
    }
}
