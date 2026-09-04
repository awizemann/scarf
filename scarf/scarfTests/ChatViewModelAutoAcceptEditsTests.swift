import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Coverage for the per-project "auto-accept edits" posture
/// (t-05f33e75):
///
/// - a project the user opted in gets ONE `session/set_mode accept_edits`
///   after its session boots, and the header chip's optimistic mirror
///   follows;
/// - a project that didn't, or a pre-v0.15 host that can't be told,
///   sends nothing at all — byte-identical to the prior release (C1);
/// - the setting itself is read through the signed store, so a record
///   Scarf didn't mint doesn't reach the wire either.
///
/// All ACP plumbing is scripted through the `acpClientFactory` seam —
/// no subprocess, no real Hermes.
@Suite struct ChatViewModelAutoAcceptEditsTests {

    // MARK: - Scripted channel

    /// Answers `initialize` / `session/new` / `session/load` /
    /// `session/set_mode` and records every method + the `modeId` of any
    /// `session/set_mode` it saw, so a test can assert both that the RPC
    /// happened and what it asked for.
    actor ModeRecordingChannel: ACPChannel {
        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private let sessionId: String

        private(set) var sentMethods: [String] = []
        private(set) var requestedModeIds: [String] = []

        var diagnosticID: String? { "mode-recording-channel" }

        init(sessionId: String) {
            self.sessionId = sessionId
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            self.incoming = inStream
            self.incomingCont = inCont
            self.stderr = errStream
            self.stderrCont = errCont
        }

        func send(_ line: String) async throws {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String
            else { return }
            sentMethods.append(method)
            if method == "session/set_mode",
               let params = obj["params"] as? [String: Any],
               let modeId = params["modeId"] as? String {
                requestedModeIds.append(modeId)
            }
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "session/new", "session/load":
                reply(["jsonrpc": "2.0", "id": id,
                       "result": ["sessionId": sessionId,
                                  "modes": ["currentModeId": "default"]]])
            case "session/prompt":
                break // hold
            default:
                reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }

        private func reply(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            incomingCont.yield(line)
        }

        func close() async {
            incomingCont.finish()
            stderrCont.finish()
        }
    }

    // MARK: - Helpers

    static func configuredHome() throws -> TempHermesHome {
        let home = try TempHermesHome()
        try "model:\n  default: test-model\n  provider: anthropic\n"
            .write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        return home
    }

    @MainActor
    static func waitUntil(
        timeoutSeconds: Double = 5,
        _ condition: @MainActor @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// A capabilities store pinned to `version` via an injected probe, so
    /// the test controls the v0.15 gate instead of whatever Hermes is
    /// installed on the machine running the suite.
    @MainActor
    static func capabilities(
        _ version: String, context: ServerContext, suite: String
    ) async -> HermesCapabilitiesStore {
        let caps = HermesCapabilities.parseLine("Hermes Agent v\(version)")
        let cache = HermesVersionCache(
            defaults: UserDefaults(suiteName: suite)!,
            probe: { _ in caps }
        )
        let store = HermesCapabilitiesStore(context: context, cache: cache)
        _ = await waitUntil { store.capabilities.semver != nil }
        return store
    }

    /// Boot a project-scoped session and return the channel it drove.
    @MainActor
    static func bootProjectSession(
        home: TempHermesHome,
        projectPath: String,
        version: String,
        optIn: Bool,
        defaultsSuite: String
    ) async -> (vm: ChatViewModel, channel: ModeRecordingChannel) {
        let vm = ChatViewModel(context: home.context)
        vm.capabilitiesStore = await capabilities(
            version, context: home.context, suite: defaultsSuite
        )
        let store = ProjectAutoAcceptEditsStore(
            suiteName: defaultsSuite, testServiceSuffix: "aae-\(UUID().uuidString)"
        )
        if optIn {
            #expect(store.setEnabled(true, projectId: projectPath))
        }
        vm.autoAcceptEditsStore = store

        let channel = ModeRecordingChannel(sessionId: "sess-AAE")
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }
        vm.startNewSession(projectPath: projectPath)
        _ = await waitUntil { vm.richChatViewModel.sessionId == "sess-AAE" }
        return (vm, channel)
    }

    // MARK: - Tests

    /// The feature: opted-in project on a v0.15 host boots into
    /// accept_edits, and the header chip says so.
    @Test @MainActor func optedInProjectSetsAcceptEditsAtSessionStart() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let (vm, channel) = await Self.bootProjectSession(
            home: home, projectPath: "/p/opted-in", version: "0.15.0",
            optIn: true, defaultsSuite: suite
        )

        let sent = await Self.waitUntil { await channel.requestedModeIds.contains("accept_edits") }
        #expect(sent, "session/set_mode accept_edits was never sent")
        // Exactly one — not one per boot stage.
        #expect(await channel.requestedModeIds == ["accept_edits"])
        #expect(vm.richChatViewModel.activeApprovalMode == .acceptEdits,
                "the header chip's mirror didn't follow the mode Scarf set")
    }

    /// A project the user never opted in must be indistinguishable from
    /// before the feature existed.
    @Test @MainActor func projectWithoutTheSettingSendsNoSetMode() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let (vm, channel) = await Self.bootProjectSession(
            home: home, projectPath: "/p/plain", version: "0.15.0",
            optIn: false, defaultsSuite: suite
        )

        // Give the boot a beat to have done the wrong thing if it were
        // going to — asserting on an absence needs the window.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await channel.sentMethods.contains("session/set_mode") == false)
        #expect(vm.richChatViewModel.activeApprovalMode == .default)
    }

    /// C1: a pre-v0.15 host doesn't understand `session/set_mode`, so an
    /// opted-in project must behave exactly as it did on the prior Scarf
    /// release — no RPC, no mirror change, no error surfaced.
    @Test @MainActor func preV015HostSendsNoSetModeEvenWhenOptedIn() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let (vm, channel) = await Self.bootProjectSession(
            home: home, projectPath: "/p/opted-in", version: "0.14.9",
            optIn: true, defaultsSuite: suite
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await channel.sentMethods.contains("session/set_mode") == false)
        #expect(vm.richChatViewModel.activeApprovalMode == .default)
        #expect(vm.acpError == nil, "a capability-degraded host must not raise an error")
    }

    /// The trust boundary, end to end: a record the user never made
    /// (written straight into defaults, no tag) doesn't reach the wire.
    /// This is the one that matters — everything else is convenience.
    @Test @MainActor func forgedSettingRecordNeverReachesTheWire() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // What an agent with a terminal can do: `defaults write`.
        defaults.set("on", forKey: "com.scarf.project.autoAcceptEdits./p/forged")

        let (vm, channel) = await Self.bootProjectSession(
            home: home, projectPath: "/p/forged", version: "0.15.0",
            optIn: false, defaultsSuite: suite
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await channel.sentMethods.contains("session/set_mode") == false)
        #expect(vm.richChatViewModel.activeApprovalMode == .default)
    }

    /// A session opened with no project scope has no per-project setting
    /// to read, so it never sets a mode.
    @Test @MainActor func projectlessChatSendsNoSetMode() async throws {
        let home = try Self.configuredHome()
        defer { home.cleanup() }
        let suite = "com.scarf.tests.autoaccept.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let vm = ChatViewModel(context: home.context)
        vm.capabilitiesStore = await Self.capabilities(
            "0.15.0", context: home.context, suite: suite
        )
        let channel = ModeRecordingChannel(sessionId: "sess-NP")
        vm.acpClientFactory = { ctx, _ in ACPClient(context: ctx) { _ in channel } }

        vm.startNewSession()
        _ = await Self.waitUntil { vm.richChatViewModel.sessionId == "sess-NP" }
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await channel.sentMethods.contains("session/set_mode") == false)
    }
}
