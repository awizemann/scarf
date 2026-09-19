import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Per-message text-to-speech: what its failures are allowed to log
/// (charter C9 — no secret ever reaches a log or a file) and what its
/// playback path is allowed to leave behind in `$TMPDIR`.
@Suite struct MessageSpeechServiceTests {

    // MARK: - F6: a failure's detail is never public in the log

    /// `SpeechError.synthesisFailed` carries a verbatim tail of the host's
    /// stdout/stderr — a provider that echoes its key in an error message
    /// puts that key in there. The public half of the log line must be the
    /// case name and nothing else.
    @Test func aSynthesisFailuresDetailNeverReachesThePublicLogHalf() {
        let secret = "sk-proj-DEADBEEFnotarealkey"
        let error = HermesSpeechService.SpeechError.synthesisFailed(
            "openai: invalid_api_key for \(secret)"
        )
        let summary = MessageSpeechService.logSummary(for: error)
        #expect(summary.publicSummary == "synthesisFailed")
        #expect(!summary.publicSummary.contains(secret))
        #expect(!summary.publicSummary.contains("openai"))
        // The detail is kept — it is the diagnosis — but only privately.
        #expect(summary.privateDetail.contains(secret))
    }

    /// Every other case names itself publicly and keeps its payload private,
    /// including an error the service doesn't know.
    @Test func everyFailureNamesOnlyItsCasePublicly() {
        let cases: [(HermesSpeechService.SpeechError, String, String)] = [
            (.providerMismatch(actualFormat: "ogg"), "providerMismatch", "ogg"),
            (.emptyAudio, "emptyAudio", ""),
            (.unexpectedOutputPath("/tmp/elsewhere.wav"), "unexpectedOutputPath", "/tmp/elsewhere.wav"),
            (.transportFailed("ssh: host unreachable"), "transportFailed", "ssh: host unreachable"),
        ]
        for (error, expectedPublic, expectedPrivate) in cases {
            let summary = MessageSpeechService.logSummary(for: error)
            #expect(summary.publicSummary == expectedPublic)
            #expect(summary.privateDetail == expectedPrivate)
        }

        struct Mystery: Error { let token = "sk-live-secret" }
        let unknown = MessageSpeechService.logSummary(for: Mystery())
        #expect(unknown.publicSummary == "Mystery")
        #expect(!unknown.publicSummary.contains("sk-live-secret"))
    }

    // MARK: - F6: an unplayable file leaves nothing behind

    /// The temp files were registered in `pendingTempFiles` BEFORE
    /// `AVAudioFile(forReading:)` could throw, and the caller's catch falls
    /// back to the system voice without deleting them — so a host that sent
    /// audio Core Audio can't open left files in `$TMPDIR` for the rest of
    /// the app's life.
    @Test @MainActor func audioThatCannotBeOpenedLeavesNoTempFilesBehind() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-play-test-\(UUID().uuidString).wav")
        try Data("not audio at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = MessageSpeechService.shared
        #expect(throws: (any Error).self) {
            try service.playAudioFilesForTesting([url])
        }
        #expect(service.pendingTempFileURLs.isEmpty, "an unopenable file stayed on the pending list")
        #expect(!FileManager.default.fileExists(atPath: url.path), "the temp file was left in $TMPDIR")
    }
}
