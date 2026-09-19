import Testing
import Foundation
import SwiftUI
import AppKit
import ScarfCore
@testable import scarf

/// F2b — four pre-existing Mac chat defects, each pinned by the test that
/// fails when its fix is reverted:
///
/// * **A** — closing a window (or switching server/profile) left the
///   `hermes acp` process running: `ContextBoundRoot.onDisappear` ended
///   the Live Voice session and nothing else.
/// * **B** — charter C10: `loadConfig()` (a synchronous file read, an SSH
///   round-trip on a remote host) ran ON the main actor at the head of
///   every session start/resume, in `switchModelPreset`, and in
///   `toggleVoice`.
/// * **C/E/F** — the composer: an unnamed text area, Return stealing an
///   IME's candidate commit, and the 5-image cap overshooting through the
///   asynchronous encode gap.
///
/// The ACP plumbing is the scripted, process-free channel
/// `ChatViewModelStartLifecycleTests.ScriptedACPChannel`.

// MARK: - A. Window close / context switch stops the ACP process

@Suite("F2b A — leaving the chat root tears the ACP process down")
struct ChatLeaveTeardownF2bTests {

    typealias Channel = ChatViewModelStartLifecycleTests.ScriptedACPChannel

    /// The fix. Pre-fix `onDisappear` called only `leaveChatVoiceLive()`,
    /// so the window closed over a live `hermes acp` (and, on a remote
    /// host, the SSH channel carrying it).
    @Test @MainActor func leavingTheChatStopsTheACPProcess() async throws {
        let home = try ChatViewModelStartLifecycleTests.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .happy(sessionId: "sess-leave"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.startNewSession()
        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready)
        let liveBeforeLeave = await ch.closed
        #expect(liveBeforeLeave == false)

        vm.leaveChat()

        let stopped = await ChatViewModelStartLifecycleTests.waitUntil { await ch.closed }
        #expect(stopped, "closing the chat root left the `hermes acp` process running")
        #expect(vm.hasActiveProcess == false)
        #expect(vm.isPreparingSession == false)
    }

    /// Teardown must also stand the reconnect ladder down. A channel that
    /// closes on its own is a DIED connection (`handleConnectionDied` →
    /// `attemptReconnect`); a channel closed BY `leaveChat` must not
    /// respawn anything, or a closed window keeps a retry loop — and its
    /// spawns — alive behind the user's back.
    @Test @MainActor func leavingDoesNotRespawnThroughTheReconnectLadder() async throws {
        let home = try ChatViewModelStartLifecycleTests.configuredHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let ch = Channel(behavior: .happy(sessionId: "sess-leave-2"))
        let calls = ChatViewModelStartLifecycleTests.CallCounter()
        vm.acpClientFactory = { ctx, _ in
            _ = calls.next()
            return ACPClient(context: ctx) { _ in ch }
        }

        vm.startNewSession()
        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready)
        let spawnsAtReady = calls.count

        vm.leaveChat()
        // A second leave (SwiftUI can re-run `onDisappear` on a rebuild)
        // must be a no-op, not a second teardown of a client that's gone.
        vm.leaveChat()

        let stopped = await ChatViewModelStartLifecycleTests.waitUntil { await ch.closed }
        #expect(stopped)
        // Give any ladder that survived teardown a bounded window to show
        // itself as a fresh factory call.
        _ = await ChatViewModelStartLifecycleTests.waitUntil(timeoutSeconds: 0.4) {
            calls.count > spawnsAtReady
        }
        #expect(calls.count == spawnsAtReady,
                "a reconnect ladder survived the leave and respawned `hermes acp`")
    }

    /// The wiring itself: the window-close / context-switch path is a
    /// SwiftUI `onDisappear` with no seam to drive headlessly, so the call
    /// is pinned at the source. Fails if `scarfApp` goes back to calling
    /// only `leaveChatVoiceLive()`.
    @Test func contextBoundRootLeaveCallsTheFullTeardown() throws {
        let appSource = try String(
            contentsOf: MacChatF2bSource.repoRoot
                .appendingPathComponent("scarf/scarf/scarfApp.swift"),
            encoding: .utf8
        )
        let lines = appSource.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(".onDisappear {") }) else {
            Issue.record("ContextBoundRoot's .onDisappear is gone — re-point this test")
            return
        }
        let body = lines[start..<min(start + 16, lines.count)].joined(separator: "\n")
        #expect(body.contains("chatViewModel.leaveChat()"),
                "the window-close path must stop ACP, not just dismiss Live Voice")
    }
}

// MARK: - B. Config reads off the main actor (charter C10)

@Suite("F2b B — no synchronous config.yaml read on the main actor")
struct ChatConfigReadOffMainF2bTests {

    typealias Channel = ChatViewModelStartLifecycleTests.ScriptedACPChannel

    /// Decorates a real transport and records, per read, WHICH THREAD it
    /// ran on. The honest signal (same one P11/P22 settled on): timing a
    /// call that kicks work off in a `Task` proves nothing.
    final class ThreadRecordingTransport: ServerTransport, @unchecked Sendable {
        private let inner: any ServerTransport
        private let lock = NSLock()
        private var _mainThreadReads: [String] = []
        private var _reads: [String] = []

        /// Paths read while ON the main thread — every entry is a C10
        /// violation.
        var mainThreadReads: [String] { lock.lock(); defer { lock.unlock() }; return _mainThreadReads }
        var reads: [String] { lock.lock(); defer { lock.unlock() }; return _reads }

        func mainThreadReads(of suffix: String) -> [String] {
            mainThreadReads.filter { $0.hasSuffix(suffix) }
        }
        func reads(of suffix: String) -> [String] {
            reads.filter { $0.hasSuffix(suffix) }
        }

        init(_ inner: any ServerTransport) { self.inner = inner }

        var contextID: ServerID { inner.contextID }
        var isRemote: Bool { inner.isRemote }
        func readFile(_ path: String) throws -> Data {
            let onMain = Thread.isMainThread
            lock.lock()
            _reads.append(path)
            if onMain { _mainThreadReads.append(path) }
            lock.unlock()
            return try inner.readFile(path)
        }
        func unguardedWriteFile(_ path: String, data: Data) throws {
            try inner.unguardedWriteFile(path, data: data)
        }
        func fileExists(_ path: String) -> Bool { inner.fileExists(path) }
        func stat(_ path: String) -> FileStat? { inner.stat(path) }
        func statAll(_ paths: [String]) -> [String: FileStat]? { inner.statAll(paths) }
        func listDirectory(_ path: String) throws -> [String] { try inner.listDirectory(path) }
        func createDirectory(_ path: String) throws { try inner.createDirectory(path) }
        func removeFile(_ path: String) throws { try inner.removeFile(path) }
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            try inner.runProcess(executable: executable, args: args, stdin: stdin, timeout: timeout)
        }
        func makeProcess(executable: String, args: [String]) -> Process {
            inner.makeProcess(executable: executable, args: args)
        }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process {
            inner.makeProcess(executable: executable, args: args, cwd: cwd)
        }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { inner.watchPaths(paths) }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            try await inner.streamScript(script, timeout: timeout)
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            inner.streamLines(executable: executable, args: args)
        }
    }

    @MainActor
    private static func makeRecordingVM(_ home: TempHermesHome) -> (ChatViewModel, ThreadRecordingTransport) {
        let vm = ChatViewModel(context: home.context)
        let recorder = ThreadRecordingTransport(home.context.makeTransport())
        vm.fileService = HermesFileService(context: home.context, transport: recorder)
        return (vm, recorder)
    }

    /// The preflight at the head of `startACPSession` — the read every
    /// session start and every resume pays. Pre-fix it was a straight
    /// `ModelPreflight.check(fileService.loadConfig())` on the main actor.
    @Test @MainActor func sessionStartReadsConfigOffTheMainActor() async throws {
        let home = try ChatViewModelStartLifecycleTests.configuredHome()
        defer { home.cleanup() }
        let (vm, recorder) = Self.makeRecordingVM(home)
        let ch = Channel(behavior: .happy(sessionId: "sess-cfg"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.startNewSession()
        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready, "the start never completed — the preflight read never landed")

        // The preflight really did read config.yaml (otherwise the
        // assertion below would be vacuous)…
        #expect(recorder.reads(of: "config.yaml").isEmpty == false)
        // …and never from the main thread.
        #expect(recorder.mainThreadReads.isEmpty,
                "config read on the main actor during session start: \(recorder.mainThreadReads)")
        vm.leaveChat()
    }

    /// "Use global default" in the mid-chat model picker resolved the
    /// default model with a main-actor `loadConfig()` — on the click.
    @Test @MainActor func switchingToTheGlobalDefaultReadsConfigOffTheMainActor() async throws {
        let home = try ChatViewModelStartLifecycleTests.configuredHome()
        defer { home.cleanup() }
        let (vm, recorder) = Self.makeRecordingVM(home)
        let ch = Channel(behavior: .happy(sessionId: "sess-switch"))
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in ch } }

        vm.startNewSession()
        let ready = await ChatViewModelStartLifecycleTests.waitUntil {
            vm.acpStatus == ChatViewModel.ACPPhase.ready
        }
        #expect(ready)
        let readsBefore = recorder.reads(of: "config.yaml").count

        vm.switchModelPreset(nil) // nil = revert to the config.yaml default

        let switched = await ChatViewModelStartLifecycleTests.waitUntil {
            await ch.sentMethods.contains("session/set_model")
        }
        #expect(switched, "session/set_model never went out")
        #expect(recorder.reads(of: "config.yaml").count > readsBefore,
                "the default-model resolution didn't read config.yaml at all")
        #expect(recorder.mainThreadReads.isEmpty,
                "config read on the main actor during the model switch: \(recorder.mainThreadReads)")
        vm.leaveChat()
    }

    /// The third site (`toggleVoice`, terminal mode) has no headless seam
    /// — it needs a live `LocalProcessTerminalView`. It and any future
    /// site are held by the source rule instead: every `loadConfig()` in
    /// `ChatViewModel` sits inside an off-main hop (`OffPool.run` or
    /// `Task.detached`), never on the main actor.
    @Test func everyChatViewModelConfigReadSitsInsideAnOffMainHop() throws {
        let path = MacChatF2bSource.repoRoot
            .appendingPathComponent("scarf/scarf/Features/Chat/ViewModels/ChatViewModel.swift")
        let lines = try String(contentsOf: path, encoding: .utf8).components(separatedBy: "\n")

        var offenders: [String] = []
        var sites = 0
        for (index, line) in lines.enumerated() where line.contains("loadConfig()") {
            // Skip prose — only real call sites count.
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || code.hasPrefix("///") { continue }
            sites += 1
            // Walk back to the nearest hop that leaves the main actor. A
            // `MainActor.run` / `await MainActor` in between means we came
            // BACK on-main before the read.
            // The common shape is the read INSIDE the hop's own closure on
            // one line (`await OffPool.run { svc.loadConfig() }`). Comments
            // never count as a hop — this file documents `OffPool.run` in
            // prose directly above the sites, and prose must not be able to
            // vouch for code.
            func isComment(_ text: String) -> Bool {
                text.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            func opensOffMainHop(_ text: String) -> Bool {
                guard !isComment(text) else { return false }
                return text.contains("OffPool.run {") || text.contains("Task.detached")
            }
            var hopped = opensOffMainHop(line)
            var backOnMain = false
            for previous in stride(from: index - 1, through: max(0, index - 40), by: -1) where !hopped {
                let text = lines[previous]
                if isComment(text) { continue }
                if text.contains("MainActor.run") { backOnMain = true }
                if opensOffMainHop(text) {
                    hopped = !backOnMain
                    break
                }
            }
            if !hopped {
                offenders.append("line \(index + 1): \(code)")
            }
        }

        #expect(sites >= 3, "expected the known config-read sites — did the file move?")
        #expect(offenders.isEmpty,
                "loadConfig() on the main actor (charter C10):\n\(offenders.joined(separator: "\n"))")
    }
}

// MARK: - C / E / F. The composer

@Suite("F2b C/E/F — composer label, IME Return, image-cap reservation")
struct ChatComposerF2bTests {

    // MARK: C — accessibility label on the composer

    /// The composer's only visible name is a placeholder overlay that is
    /// `allowsHitTesting(false)` and vanishes as soon as the field has
    /// content, so the text area itself was nameless: nothing for
    /// VoiceOver to announce and nothing for Voice Control to hear.
    @Test @MainActor func composerTextAreaCarriesAnAccessibilityLabel() async throws {
        let labels = MacChatF2bSource.axLabels(of:
            RichChatInputBar(onSend: { _, _, _ in }, isEnabled: true)
                .frame(width: 600)
        )
        #expect(labels.contains("Message Hermes"),
                "composer text area has no accessibility label; saw: \(labels)")
    }

    /// The message speaker button's label is already localized and
    /// state-dependent — pinned here so the pair stays covered.
    @Test func speakerButtonLabelIsLocalizedAndStateful() {
        let idle = SpeakMessageButtonState(isPlaying: false, isLoading: false, liveVoiceActive: false)
        let playing = SpeakMessageButtonState(isPlaying: true, isLoading: false, liveVoiceActive: false)
        #expect(idle.accessibilityLabel.isEmpty == false)
        #expect(idle.accessibilityLabel != playing.accessibilityLabel)
    }

    // MARK: E — Return during IME composition

    /// Return while the input method holds MARKED TEXT (the underlined,
    /// uncommitted run a Japanese/Chinese/Korean IME shows while the user
    /// picks a candidate) is the user committing that candidate — not
    /// sending. Pre-fix the composer swallowed it and sent a
    /// half-composed sentence.
    @Test func returnDuringIMECompositionDoesNotSend() {
        #expect(RichChatInputBar.shouldSendOnReturn(hasMarkedText: true, modifiers: []) == false)
        // Every modifier combination stays with the IME while composing.
        #expect(RichChatInputBar.shouldSendOnReturn(hasMarkedText: true, modifiers: .shift) == false)
    }

    /// …and the unchanged rules: a plain Return sends, Shift-Return makes
    /// a newline.
    @Test func returnSendsWhenNothingIsBeingComposed() {
        #expect(RichChatInputBar.shouldSendOnReturn(hasMarkedText: false, modifiers: []) == true)
        #expect(RichChatInputBar.shouldSendOnReturn(hasMarkedText: false, modifiers: .shift) == false)
    }

    // MARK: F — the 5-image cap across the async encode gap

    /// A stand-in for `ImageEncoder` that suspends until the test lets it
    /// finish — the asynchronous gap the old count-then-append check fell
    /// through.
    actor SuspendingEncoder {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func encode() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func releaseAll() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private static func attachment(_ n: Int) -> ChatImageAttachment {
        ChatImageAttachment(
            mimeType: "image/png",
            base64Data: "AAAA",
            thumbnailBase64: nil,
            filename: "img-\(n).png",
            approximateByteCount: 4
        )
    }

    /// The bug: two quick drops both measured themselves against the same
    /// pre-encode `attachments.count`, so 4 + 4 images landed as 8 with a
    /// cap of 5. Reserving synchronously makes the second drop see the
    /// first one's in-flight encodes.
    @Test @MainActor func quickSuccessiveDropsCannotExceedTheCap() async {
        let slots = ComposerAttachmentSlots(capacity: 5)
        let encoder = SuspendingEncoder()

        // Drop 1: four images. All four are accepted and start encoding.
        let firstGranted = slots.reserve(upTo: 4)
        #expect(firstGranted == 4)

        let encodes = (0..<firstGranted).map { n in
            Task { @MainActor in
                await encoder.encode()
                slots.commit(Self.attachment(n))
            }
        }

        // Drop 2 lands while all four encodes are still suspended. Pre-fix
        // this saw `attachments.count == 0` and took four more slots.
        let secondGranted = slots.reserve(upTo: 4)
        #expect(secondGranted == 1, "the cap was measured against a stale, pre-encode count")
        #expect(slots.isFull)
        #expect(slots.reserve(upTo: 3) == 0)

        await encoder.releaseAll()
        for encode in encodes { await encode.value }

        #expect(slots.attachments.count == 4)
        // The second drop's single reservation is still outstanding.
        #expect(slots.used == 5)
        #expect(slots.attachments.count <= slots.capacity)
    }

    /// A failed encode must hand its slot back, or a run of bad drops
    /// permanently shrinks the composer's capacity.
    @Test @MainActor func failedEncodesReleaseTheirSlots() {
        let slots = ComposerAttachmentSlots(capacity: 5)
        #expect(slots.reserve(upTo: 5) == 5)
        #expect(slots.free == 0)
        for _ in 0..<5 { slots.release() }
        #expect(slots.free == 5)
        #expect(slots.isEncoding == false)
        #expect(slots.attachments.isEmpty)
    }

    /// Sending drains the attachments but leaves an in-flight encode's
    /// reservation alone — it belongs to the next message.
    @Test @MainActor func sendingDrainsAttachmentsButKeepsInFlightReservations() {
        let slots = ComposerAttachmentSlots(capacity: 5)
        slots.reserve(upTo: 2)
        slots.commit(Self.attachment(0))
        #expect(slots.attachments.count == 1)
        #expect(slots.reserved == 1)

        let drained = slots.drain()
        #expect(drained.count == 1)
        #expect(slots.attachments.isEmpty)
        #expect(slots.reserved == 1, "a send must not cancel an encode that's still running")

        slots.commit(Self.attachment(1))
        #expect(slots.attachments.count == 1)
        #expect(slots.reserved == 0)
    }
}

// MARK: - Shared helpers

enum MacChatF2bSource {

    /// Repo root, for the source-level pins above
    /// (`…/scarf/scarfTests/<this file>`).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    /// Render `view` in an `NSHostingView` and collect every
    /// accessibility label AppKit builds for it. Same probe as
    /// `CronViewAccessibilityTreeTests` — `accessibilityEnhancedUserInterface`
    /// is what makes AppKit build the tree at all.
    @MainActor
    static func axLabels(of view: some View) -> [String] {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        var labels: [String] = []
        collect(host, depth: 0, into: &labels)
        window.orderOut(nil)
        return labels
    }

    @MainActor
    private static func collect(_ element: Any, depth: Int, into labels: inout [String]) {
        guard depth < 14 else { return }
        let obj = element as AnyObject
        if let label = obj.accessibilityLabel?(), !label.isEmpty { labels.append(label) }
        for child in obj.accessibilityChildren?() ?? [] {
            collect(child, depth: depth + 1, into: &labels)
        }
    }
}
