import AVFoundation
import Foundation
import Testing
@testable import ScarfIOS

// MARK: - Mocks
//
// File-scope (not nested in the suite) so each mock carries an explicit
// isolation: recorder mocks are @MainActor to match the @MainActor
// protocols they conform to; the transcriber / permission mocks stay
// nonisolated to match theirs. @MainActor on the suite would otherwise
// propagate to nested types and fight the nonisolated requirements.

@MainActor
private final class MockRecorder: AudioMemoRecording {
    var recordCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var recordSucceeds = true

    func record() -> Bool {
        recordCalls += 1
        return recordSucceeds
    }

    func stop() { stopCalls += 1 }
    func cancel() { cancelCalls += 1 }
}

@MainActor
private final class MockRecorderFactory: AudioMemoRecorderFactory {
    let recorder = MockRecorder()
    var factoryError: Error?

    func makeRecorder(fileURL: URL) throws -> any AudioMemoRecording {
        if let factoryError { throw factoryError }
        return recorder
    }
}

private struct MockPermissions: PushToTalkPermissionChecking {
    let state: PermissionState
    let requestResult: PushToTalkPermission
    let requestCalls = Counter()

    init(status: PushToTalkPermission, requestResult: PushToTalkPermission = .granted) {
        self.state = PermissionState(status)
        self.requestResult = requestResult
    }

    func authorizationStatus() -> PushToTalkPermission { state.current }

    func requestAuthorization() async -> PushToTalkPermission {
        requestCalls.bump()
        // Mirrors the real client: once the prompts are answered, the
        // status snapshot reports the resolved state.
        state.current = requestResult
        return requestResult
    }
}

/// Lock-guarded permission state — `authorizationStatus` is a
/// synchronous nonisolated requirement, so the mutation from the async
/// request path has to be thread-safe.
private final class PermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PushToTalkPermission

    init(_ value: PushToTalkPermission) {
        self.value = value
    }

    var current: PushToTalkPermission {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

private struct MockTranscriber: SpeechTranscribing {
    enum Outcome: Sendable {
        case text(String)
        case silent
        case failure
        /// Mirrors `OnDeviceSpeechTranscriber`'s own defense-in-depth
        /// check — exercised even though `startRecording()` should
        /// already have refused to record in this state, so a bug in
        /// that pre-flight check can't regress into a silent
        /// server-side transcription going unnoticed.
        case onDeviceUnsupported
        /// Simulates a recognizer completion handler that never fires.
        /// `Task.sleep` still honors cancellation the way a correctly
        /// fixed `OnDeviceSpeechTranscriber` must — this is what proves
        /// `PushToTalkController`'s bounded-timeout race actually
        /// unblocks: the timeout side wins, cancels this task, and
        /// `Task.sleep` throws `CancellationError` promptly instead of
        /// hanging for the full (unrealistically long) duration below.
        case hangs
    }

    let outcome: Outcome
    let receivedURLs = URLSink()

    func transcribe(fileAt url: URL) async throws -> String {
        receivedURLs.append(url)
        switch outcome {
        case .text(let value): return value
        case .silent: return "   \n"
        case .failure: throw DictationError(reason: .recognizerUnavailable)
        case .onDeviceUnsupported: throw DictationError(reason: .onDeviceRecognitionUnsupported)
        case .hangs:
            // Parks until cancelled — no duration to pick (house rule:
            // no fixed sleeps in tests; see HermesP38SourceSweepTests).
            let (stream, continuation) = AsyncStream<Never>.makeStream()
            for await _ in stream {}
            withExtendedLifetime(continuation) {}
            throw CancellationError()
        }
    }
}

/// Stand-in for `OnDeviceDictationAvailabilityChecking` — defaults to
/// available so every existing test keeps exercising the happy path
/// without threading a new parameter through.
private struct MockDictationAvailability: OnDeviceDictationAvailabilityChecking {
    let available: Bool
    func isOnDeviceRecognitionAvailable() -> Bool { available }
}

/// Lock-guarded int — `requestAuthorization` runs inside a MainActor
/// task today, but the protocol doesn't promise that.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    @discardableResult
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

private final class URLSink: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

// MARK: - Tests

/// Contract coverage for the composer push-to-talk state machine:
/// permission gating, hold/cancel/release transitions, transcript
/// delivery, and memo cleanup. All collaborators are mocks — no
/// microphone, no SFSpeechRecognizer, no timing assertions.
@MainActor
@Suite struct PushToTalkControllerTests {

    private func makeController(
        permissions: MockPermissions,
        factory: MockRecorderFactory = MockRecorderFactory(),
        outcome: MockTranscriber.Outcome = .text("Hello from dictation"),
        dictationAvailable: Bool = true,
        transcriptionTimeout: Duration = .seconds(5),
        noticeLifetime: Duration = .seconds(4)
    ) -> (controller: PushToTalkController, recorder: MockRecorder, transcriber: MockTranscriber) {
        let transcriber = MockTranscriber(outcome: outcome)
        let controller = PushToTalkController(
            permissions: permissions,
            recorderFactory: factory,
            transcriber: transcriber,
            dictationAvailability: MockDictationAvailability(available: dictationAvailable),
            makeFileURL: Self.makeMemoFile,
            transcriptionTimeout: transcriptionTimeout,
            noticeLifetime: noticeLifetime
        )
        return (controller, factory.recorder, transcriber)
    }

    /// Creates a real file in tmp so the deletion assertions exercise
    /// the actual FileManager path. Nonisolated so the reference can
    /// cross into the controller's `@Sendable` file-URL seam.
    nonisolated private static func makeMemoFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ptt-test-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x52, 0x49, 0x46, 0x46]))
        return url
    }

    /// Poll with early exit (the repo's substitute for timing-dependent
    /// tests): yields the main actor so the controller's spawned task
    /// can run, returning as soon as the predicate holds.
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Happy path

    @Test func holdRecordsThenReleaseDeliversTranscript() async throws {
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        #expect(controller.phase == .recording)
        #expect(recorder.recordCalls == 1)

        controller.holdReleased()
        #expect(controller.phase == .transcribing)
        #expect(recorder.stopCalls == 1)

        await waitUntil { controller.phase == .idle }
        #expect(controller.transcript?.text == "Hello from dictation")
        #expect(controller.notice == nil)

        // The memo URL was handed to the transcriber and the file was
        // deleted afterwards — dictation audio never lingers.
        let received = transcriber.receivedURLs.values
        try #require(received.count == 1)
        let memo = try #require(received.first)
        #expect(FileManager.default.fileExists(atPath: memo.path) == false)
    }

    @Test func consecutiveTakesDeliverDistinctTranscriptValues() async {
        let (controller, _, _) = makeController(
            permissions: MockPermissions(status: .granted),
            outcome: .text("same words")
        )

        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.phase == .idle }
        let first = controller.transcript

        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.transcript?.id != first?.id }

        #expect(controller.transcript?.text == "same words")
        #expect(controller.transcript?.id != first?.id)
    }

    // MARK: - Permission gating

    @Test func deniedMicrophoneNeverRecords() {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .microphoneDenied)
        )

        controller.holdBegan()
        #expect(controller.phase == .idle)
        #expect(recorder.recordCalls == 0)
        #expect(controller.notice == .microphonePermissionDenied)
    }

    @Test func deniedSpeechNeverRecords() {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .speechDenied)
        )

        controller.holdBegan()
        #expect(controller.phase == .idle)
        #expect(recorder.recordCalls == 0)
        #expect(controller.notice == .speechPermissionDenied)
    }

    @Test func undeterminedPromptsThenRecordsOnNextHoldAfterGrant() async {
        let permissions = MockPermissions(status: .undetermined, requestResult: .granted)
        let (controller, recorder, _) = makeController(permissions: permissions)

        controller.holdBegan()
        // The system prompts take over; recording must NOT start while
        // the user is answering them.
        #expect(recorder.recordCalls == 0)
        await waitUntil { permissions.requestCalls.value == 1 }
        #expect(controller.phase == .idle)
        #expect(controller.notice == nil)

        // Once granted, the next hold records immediately.
        controller.holdBegan()
        #expect(controller.phase == .recording)
        #expect(recorder.recordCalls == 1)
        controller.holdCancelled()
    }

    @Test func undeterminedDeniedByPromptSurfacesNotice() async {
        let permissions = MockPermissions(status: .undetermined, requestResult: .speechDenied)
        let (controller, recorder, _) = makeController(permissions: permissions)

        controller.holdBegan()
        await waitUntil { controller.notice == .speechPermissionDenied }
        #expect(controller.phase == .idle)
        #expect(recorder.recordCalls == 0)
    }

    // MARK: - Failure paths

    @Test func silentTakeSurfacesNothingHeard() async {
        let (controller, _, _) = makeController(
            permissions: MockPermissions(status: .granted),
            outcome: .silent
        )

        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.phase == .idle }

        #expect(controller.transcript == nil)
        #expect(controller.notice == .nothingHeard)
    }

    @Test func transcriptionFailureSurfacesNoticeAndStaysIdle() async {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted),
            outcome: .failure
        )

        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.phase == .idle }

        #expect(controller.transcript == nil)
        #expect(controller.notice == .transcriptionFailed)
        #expect(recorder.stopCalls == 1)
    }

    /// P1 fix (t-0fbb1c3c): a recognizer whose completion handler never
    /// fires must not park the composer in `.transcribing` forever —
    /// that disables both dictation and Live Voice until the app
    /// relaunches. The bounded timeout must win within its window even
    /// though the mock's own "recognition" never completes on its own.
    @Test func hungTranscriptionResetsToIdleWithNoticeAfterTimeout() async {
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted),
            outcome: .hangs,
            transcriptionTimeout: .milliseconds(50)
        )

        controller.holdBegan()
        controller.holdReleased()
        #expect(controller.phase == .transcribing)

        await waitUntil { controller.phase == .idle }

        #expect(controller.transcript == nil)
        #expect(controller.notice == .transcriptionFailed)
        #expect(recorder.stopCalls == 1)
        #expect(transcriber.receivedURLs.values.count == 1)
    }

    @Test func recorderFailingToStartSurfacesNoticeWithoutTranscribing() {
        let factory = MockRecorderFactory()
        factory.recorder.recordSucceeds = false
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted),
            factory: factory
        )

        controller.holdBegan()
        #expect(controller.phase == .idle)
        #expect(recorder.recordCalls == 1)
        #expect(transcriber.receivedURLs.values.isEmpty)
        #expect(controller.notice == .recorderFailed)

        // Releasing after a failed start is a no-op, not a crash.
        controller.holdReleased()
        #expect(controller.phase == .idle)
    }

    @Test func throwingFactorySurfacesRecorderFailed() {
        let factory = MockRecorderFactory()
        factory.factoryError = DictationError(reason: .recognizerUnavailable)
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted),
            factory: factory
        )

        controller.holdBegan()
        #expect(controller.phase == .idle)
        #expect(recorder.recordCalls == 0)
        #expect(controller.notice == .recorderFailed)
    }

    // MARK: - Cancel + guard rails

    @Test func dragCancelDiscardsTakeWithoutTranscription() async {
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        controller.holdCancelled()

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCalls == 1)
        #expect(recorder.stopCalls == 0)
        #expect(transcriber.receivedURLs.values.isEmpty)
        #expect(controller.transcript == nil)
        #expect(controller.notice == .cancelled)
    }

    @Test func releaseWithoutHoldIsIgnored() {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdReleased()
        #expect(controller.phase == .idle)
        #expect(recorder.stopCalls == 0)
    }

    @Test func holdWhileTranscribingIsIgnored() async {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        controller.holdReleased()
        #expect(controller.phase == .transcribing)

        // A second press during transcription must not restart the
        // recorder or clobber the in-flight take.
        controller.holdBegan()
        #expect(controller.phase == .transcribing)
        #expect(recorder.recordCalls == 1)

        await waitUntil { controller.phase == .idle }
        #expect(controller.transcript?.text == "Hello from dictation")
    }

    // MARK: - Format contract

    @Test func recorderFactoryEmits16kHzMono16BitWAV() {
        let settings = AVAudioMemoRecorderFactory.audioSettings()
        #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
        #expect(settings[AVSampleRateKey] as? Double == 16_000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
        #expect(settings[AVLinearPCMIsBigEndianKey] as? Bool == false)
    }

    // MARK: - On-device privacy contract

    /// The core P1 fix: when on-device recognition can't run for the
    /// current locale/device, dictation must refuse to record at all —
    /// never fall back to Apple's servers, which is what
    /// `NSSpeechRecognitionUsageDescription` promises never happens.
    @Test func onDeviceUnavailableRefusesToRecordAtAll() {
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted),
            dictationAvailable: false
        )

        controller.holdBegan()

        #expect(controller.phase == .idle)
        #expect(recorder.recordCalls == 0)
        #expect(transcriber.receivedURLs.values.isEmpty)
        #expect(controller.notice == .onDeviceUnavailable)
    }

    /// Defense-in-depth: even if a future change lets recording start
    /// while on-device support is unavailable, the transcriber's own
    /// refusal must surface the same honest notice, not a generic
    /// "try again" that implies the request silently succeeded.
    @Test func transcriberOnDeviceRefusalSurfacesOnDeviceUnavailableNotice() async {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted),
            outcome: .onDeviceUnsupported
        )

        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.phase == .idle }

        #expect(controller.transcript == nil)
        #expect(controller.notice == .onDeviceUnavailable)
        #expect(recorder.stopCalls == 1)
    }

    // MARK: - Audio session interruption

    @Test func interruptionBeganWhileRecordingDiscardsTakeAndSurfacesNotice() {
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        #expect(controller.phase == .recording)

        controller.handleAudioSessionInterruption(began: true)

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCalls == 1)
        #expect(recorder.stopCalls == 0)
        #expect(transcriber.receivedURLs.values.isEmpty)
        #expect(controller.notice == .interrupted)
    }

    /// The interruption *ending* must not auto-resume recording — the
    /// hold gesture that started the take is long gone by the time a
    /// phone call ends.
    @Test func interruptionEndingDoesNotResumeRecording() {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        controller.handleAudioSessionInterruption(began: false)

        #expect(controller.phase == .recording)
        #expect(recorder.cancelCalls == 0)
    }

    @Test func interruptionWhileIdleIsIgnored() {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.handleAudioSessionInterruption(began: true)

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCalls == 0)
        #expect(controller.notice == nil)
    }

    // MARK: - View / app lifecycle teardown

    @Test func viewDisappearingWhileRecordingCancelsTakeLikeADragAway() {
        let (controller, recorder, transcriber) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        controller.handleViewDisappearing()

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCalls == 1)
        #expect(transcriber.receivedURLs.values.isEmpty)
        #expect(controller.notice == .cancelled)
    }

    /// A transcription already in flight when the view disappears must
    /// not deliver a transcript or notice afterwards — nobody is
    /// watching the composer to review it — but phase must still
    /// settle back to `.idle` so a later reappearance isn't stuck
    /// showing "Transcribing…" forever.
    @Test func viewDisappearingWhileTranscribingDropsResultSilently() async {
        let (controller, _, _) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.holdBegan()
        controller.holdReleased()
        #expect(controller.phase == .transcribing)

        controller.handleViewDisappearing()

        await waitUntil { controller.phase == .idle }
        #expect(controller.transcript == nil)
        #expect(controller.notice == nil)
    }

    @Test func viewDisappearingWhileIdleIsANoOp() {
        let (controller, recorder, _) = makeController(
            permissions: MockPermissions(status: .granted)
        )

        controller.handleViewDisappearing()

        #expect(controller.phase == .idle)
        #expect(recorder.cancelCalls == 0)
    }

    // MARK: - Settings deep link contract

    /// Only denials the user can actually fix from Settings should
    /// offer the deep link — a restricted/MDM device or an
    /// unsupported locale has no toggle to flip there.
    @Test func settingsDeepLinkOnlyOffersFixableDenials() {
        #expect(PushToTalkNotice.microphonePermissionDenied.opensSystemSettings)
        #expect(PushToTalkNotice.speechPermissionDenied.opensSystemSettings)
        for notice: PushToTalkNotice in [
            .permissionsRestricted, .onDeviceUnavailable, .recorderFailed,
            .transcriptionFailed, .nothingHeard, .cancelled, .interrupted,
        ] {
            #expect(!notice.opensSystemSettings)
        }
    }

    // MARK: - Notice lifetime

    /// Two IDENTICAL notices in a row each get their own window. The
    /// auto-clear used to dedupe by value (`notice == snapshot`), so the
    /// first take's timer cleared the second take's notice early — the
    /// user saw "nothing heard" flash away after a fraction of a second.
    @Test func asecondIdenticalNoticeGetsItsOwnFullWindow() async {
        let (controller, _, _) = makeController(
            permissions: MockPermissions(status: .granted),
            outcome: .silent,
            noticeLifetime: .milliseconds(400)
        )

        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.notice == .nothingHeard }
        try? await Task.sleep(for: .milliseconds(250))

        // Same notice again, a quarter of a second in.
        controller.holdBegan()
        controller.holdReleased()
        await waitUntil { controller.phase == .idle }
        #expect(controller.notice == .nothingHeard)

        // Past the FIRST notice's window: the second one must still show.
        try? await Task.sleep(for: .milliseconds(250))
        #expect(controller.notice == .nothingHeard, "the first take's timer cleared the second take's notice")

        // Past its own window: gone.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(controller.notice == nil)
    }
}
