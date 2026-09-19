import Testing
import Foundation
import CryptoKit
@testable import ScarfCore

/// Contract: a Live Voice turn is sent over ACP as
/// `[resource(turn note + spoken context), text(spoken words)]`.
///
/// Hermes @ v2026.9.14 persists only `.text` blocks (`_extract_text`,
/// `acp_adapter/content.py:224-226` → `persist_user_message`,
/// `acp_adapter/server.py:773-776`) and inlines embedded-resource text into
/// the model input (`_content_blocks_to_openai_user_content`,
/// `content.py:249-275` via `_embedded_resource_to_parts`, `:185-194`).
/// The note is `VOICE_LIVE_TURN_NOTE` / `voice_live_turn_note(context)`,
/// `tools/voice_live.py:73-90`.
@Suite struct VoiceLiveTurnNoteContractTests {

    // MARK: wire shape

    @Test func notesPrecedeTheTextBlock() throws {
        let context = "User: the dentist one\nVoice assistant: which day?"
        let note = VoiceLiveTurnNote.contextNote(context: context)
        let blocks = ACPClient.promptBlocks(text: "thursday not friday", images: [], contextNotes: [note])
        try #require(blocks.count == 2)
        #expect(Set(blocks[0].keys) == ["type", "resource"])
        #expect(blocks[0]["type"] as? String == "resource")
        #expect(blocks[0]["resource"] as? [String: String] == [
            "uri": "scarf://voice-live/voice-live-turn-note",
            "mimeType": "text/plain",
            "text": VoiceLiveTurnNote.note + "\n[Recent spoken conversation, newest last:\n" + context + "]",
        ])
        #expect(blocks[1] as? [String: String] == ["type": "text", "text": "thursday not friday"])
    }

    @Test func withoutNotesThePayloadIsTheImagesShape() throws {
        let image = ChatImageAttachment(mimeType: "image/png", base64Data: "AAAA", thumbnailBase64: nil, filename: nil, approximateByteCount: 3)
        let blocks = ACPClient.promptBlocks(text: "hi", images: [image], contextNotes: [])
        try #require(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == "hi")
        #expect(blocks[1]["type"] as? String == "image")
        #expect(blocks[1]["data"] as? String == "AAAA")
        #expect(blocks[1]["mimeType"] as? String == "image/png")
    }

    /// Pins the vendored note byte-for-byte even where no tag checkout
    /// exists (CI): the SHA-256 of `VOICE_LIVE_TURN_NOTE` at
    /// `tools/voice_live.py:73-81` @ v2026.9.14, computed from the tagged
    /// file (`git show "v2026.9.14:tools/voice_live.py"`, literal parsed with
    /// Python's `ast`). A Hermes release audit that refreshes the note
    /// updates this.
    @Test func vendoredNoteHashMatchesTheTag() {
        let digest = SHA256.hash(data: Data(VoiceLiveTurnNote.note.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "4daa3902ecfe6c7d3531b1f19887eafa6d7b06d5e78c208506b2448e0a9899c5")
    }

    @Test func emptyContextIsTheBareNote() {
        #expect(VoiceLiveTurnNote.text(context: "  \n ") == VoiceLiveTurnNote.note)
        #expect(VoiceLiveTurnNote.note.hasPrefix("[Note: this message is a delegation from a live spoken conversation."))
        #expect(VoiceLiveTurnNote.note.hasSuffix("Do not claim an action succeeded before it actually did.]"))
    }

    @Test func requestCarriesTheNoteForItsContext() {
        let request = VoiceTurnRequest(id: "d1", prompt: "yes", context: "Voice assistant: shall I?\nUser: yes")
        #expect(request.contextNotes == [VoiceLiveTurnNote.contextNote(context: "Voice assistant: shall I?\nUser: yes")])
    }

    @Test func aSupersedingTurnIsTextOnlyOnTheWire() throws {
        let request = VoiceTurnRequest(id: "d2", prompt: "no, thursday", context: "User: no, thursday",
                                       supersedesCancelledTurn: true)
        #expect(request.contextNotes.isEmpty)
        let blocks = ACPClient.promptBlocks(text: request.prompt, images: [], contextNotes: request.contextNotes)
        try #require(blocks.count == 1)
        #expect(blocks[0] as? [String: String] == ["type": "text", "text": "no, thursday"])
    }

    // MARK: Hermes's own parser (runs only where a tag-identical Hermes checkout exists)

    /// Feeds Scarf's exact blocks through Hermes's ACP schema and content
    /// parser, and compares the vendored note with Hermes's function. Runs
    /// only when `~/.hermes/hermes-agent` has a venv AND its
    /// `acp_adapter/content.py` + `tools/voice_live.py` are identical to tag
    /// v2026.9.14 — so it tests the tagged behaviour, never a drifted tree.
    @Test(.enabled { await HermesTagCheckout.available(files: ["acp_adapter/content.py", "tools/voice_live.py"]) })
    func hermesParserPersistsOnlyTheSpokenWords() async throws {
        let context = "User: the dentist one\nVoice assistant: which day?"
        let blocks = ACPClient.promptBlocks(
            text: "thursday not friday", images: [], contextNotes: [VoiceLiveTurnNote.contextNote(context: context)])
        let blocksJSON = String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        let script = """
        import json, sys
        from acp.schema import PromptRequest
        from acp_adapter.content import _extract_text, _content_blocks_to_openai_user_content
        import tools.voice_live as vl
        data = json.loads(sys.stdin.read())
        req = PromptRequest.model_validate({"sessionId": "s", "prompt": json.loads(data["blocks"])})
        print(json.dumps({
            "persisted": _extract_text(req.prompt).strip(),
            "model": _content_blocks_to_openai_user_content(req.prompt),
            "note": vl.voice_live_turn_note(data["context"]),
        }))
        """
        let input = try JSONSerialization.data(withJSONObject: ["blocks": blocksJSON, "context": context])
        let output = try await HermesTagCheckout.runPython(script, stdin: input)
        let result = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(result["persisted"] as? String == "thursday not friday")
        let model = try #require(result["model"] as? String)
        #expect(model.hasPrefix("[Attached file: voice-live-turn-note]"))
        #expect(model.contains(VoiceLiveTurnNote.note))
        #expect(model.hasSuffix("\nthursday not friday"))
        #expect(result["note"] as? String == VoiceLiveTurnNote.text(context: context))
    }
}

extension VoiceLiveTurnNoteContractTests {
    /// Why superseding turns go text-only, run against Hermes's own code:
    /// after `cancel` stores `interrupted_prompt_text`
    /// (`acp_adapter/server.py:617-619` @ v2026.9.14),
    /// `_rewrite_prompt_for_interrupt` (`:672-694`) consumes it for Scarf's
    /// text-only superseding blocks (framing the new words as a correction)
    /// and leaves it in place for note-bearing blocks, where it would attach
    /// to the chat's next typed prompt. Runs only against a tag-identical
    /// checkout.
    @Test(.enabled { await HermesTagCheckout.available(files: ["acp_adapter/server.py", "acp_adapter/content.py"]) })
    func hermesConsumesTheCancelledPromptOnlyForTextOnlyTurns() async throws {
        let superseding = VoiceTurnRequest(id: "d2", prompt: "no, thursday", context: "User: no, thursday",
                                           supersedesCancelledTurn: true)
        let first = VoiceTurnRequest(id: "d2", prompt: "no, thursday", context: "User: no, thursday")
        func blocksJSON(_ request: VoiceTurnRequest) throws -> String {
            let blocks = ACPClient.promptBlocks(text: request.prompt, images: [], contextNotes: request.contextNotes)
            return String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        }
        let script = """
        import json, sys, threading
        from types import SimpleNamespace
        from acp.schema import PromptRequest, TextContentBlock
        from acp_adapter.content import _extract_text, _content_blocks_to_openai_user_content
        from acp_adapter.server import HermesACPAgent
        out = {}
        data = json.loads(sys.stdin.read())
        for name in ("superseding", "first"):
            prompt = PromptRequest.model_validate({"sessionId": "s", "prompt": json.loads(data[name])}).prompt
            state = SimpleNamespace(runtime_lock=threading.Lock(), is_running=False,
                                    interrupted_prompt_text="book the dentist friday")
            text, content = HermesACPAgent._rewrite_prompt_for_interrupt(
                None, state, _extract_text(prompt).strip(), _content_blocks_to_openai_user_content(prompt),
                all(isinstance(b, TextContentBlock) for b in prompt))
            out[name] = {"persisted": text, "left": state.interrupted_prompt_text}
        print(json.dumps(out))
        """
        let input = try JSONSerialization.data(withJSONObject: [
            "superseding": try blocksJSON(superseding), "first": try blocksJSON(first),
        ])
        let output = try await HermesTagCheckout.runPython(script, stdin: input)
        let result = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: [String: String]])
        #expect(result["superseding"]?["persisted"]
                == "book the dentist friday\n\nUser correction/guidance after interrupt: no, thursday")
        #expect(result["superseding"]?["left"] == "")
        #expect(result["first"]?["persisted"] == "no, thursday")
        #expect(result["first"]?["left"] == "book the dentist friday")   // would leak into the next typed prompt
    }
}

/// Locates a local Hermes checkout whose named files are byte-identical to
/// the tag Scarf's Live Voice was verified against.
enum HermesTagCheckout {
    static let tag = "v2026.9.14"
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent")
    }
    static var python: URL { root.appendingPathComponent("venv/bin/python") }

    /// Async so the `git diff` never parks a cooperative-pool thread while
    /// the test plan evaluates the condition.
    static func available(files: [String]) async -> Bool {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        guard let out = try? await ShellTestRunner.run(
            "/usr/bin/git", arguments: ["-C", root.path, "diff", "--quiet", tag, "--"] + files, timeout: 60
        ) else { return false }
        return out.status == 0
        #else
        return false
        #endif
    }

    static func runPython(_ script: String, stdin: Data) async throws -> String {
        #if os(macOS)
        var env = ProcessInfo.processInfo.environment
        env["HERMES_HOME"] = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-hermes-contract-\(UUID().uuidString)").path
        // A hang guard, not an assertion: importing Hermes's ACP adapter takes
        // ~0.3 s idle but blew a 30 s bound under a load average of ~90.
        let out = try await ShellTestRunner.run(python.path, arguments: ["-c", script], stdin: stdin, environment: env,
                                          currentDirectory: FileManager.default.temporaryDirectory, timeout: 180)
        return out.stdout.split(separator: "\n").last.map(String.init) ?? ""
        #else
        return ""
        #endif
    }
}
