import Foundation
import Testing

/// The transcript's ForEach closure reruns on streaming updates. Reading the
/// density styles inside it costs a UserDefaults read per row, which held the
/// main thread when the settings file was large and being rewritten.
@Suite struct ChatListDensityReadTests {
    @Test func theTranscriptReadsDensityOncePerListNotPerRow() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .appendingPathComponent("scarf/Features/Chat/Views/RichChatMessageList.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let loop = try #require(text.range(of: "ForEach(groups) { group in"))
        let call = try #require(text.range(of: "group.isHiddenByDensity(", range: loop.upperBound..<text.endIndex))
        let insideLoop = text[loop.upperBound..<call.upperBound]
        let args = text[call.upperBound...].prefix(while: { $0 != "\n" })
        #expect(!insideLoop.contains("listToolCardStyle"))
        #expect(!args.contains("listToolCardStyle"))
        #expect(!args.contains("listReasoningStyle"))
    }
}
