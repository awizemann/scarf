import Testing
import Foundation
import ScarfCore
@testable import scarf

/// R10 (Hermes v0.21.5 audit remediation) — Mac chat controller fixes:
///
/// - S03-F3: the header's YOLO chip follows the approvals mode Hermes
///   actually enforces (`off`, including bare YAML `no`/`false`), not a
///   `"yolo"` value Hermes has never accepted.
/// - S03-F4 / t-fa0043f6: the chat sidebar's rename and delete run the
///   `hermes sessions …` CLI off the main actor.
///
/// The S02-F3 autostart replay case lives with the other start-pipeline
/// tests (`ChatViewModelStartLifecycleTests.autoStartResumeDropsTheLoadReplay`).
@Suite struct ChatControllersR10MacTests {

    typealias Lifecycle = ChatViewModelStartLifecycleTests

    // MARK: - S03-F3 YOLO chip

    private static let v014 = HermesCapabilities.parseLine("Hermes Agent v0.14.0")
    private static let v013 = HermesCapabilities.parseLine("Hermes Agent v0.13.0")

    /// Parsed from YAML the way the chat reads it
    /// (`HermesConfig.storedApprovalMode`), then fed to the chip rule.
    private static func chip(_ yaml: String, _ caps: HermesCapabilities = v014) -> Bool {
        SessionInfoBar.showsApprovalsOffWarning(
            mode: HermesConfig(yaml: yaml).storedApprovalMode,
            capabilities: caps
        )
    }

    @Test func chipShowsWhenApprovalsAreOff() {
        #expect(Self.chip("approvals:\n  mode: off\n"))
        // Bare YAML booleans Hermes reads as `off`
        // (`_normalize_approval_mode`, tools/approval_context.py:205-206).
        #expect(Self.chip("approvals:\n  mode: false\n"))
        #expect(Self.chip("approvals:\n  mode: no\n"))
        // The one quoted spelling that is still `off`.
        #expect(Self.chip("approvals:\n  mode: \"off\"\n"))
    }

    @Test func chipHiddenWhenApprovalsAreOn() {
        #expect(!Self.chip("approvals:\n  mode: manual\n"))
        #expect(!Self.chip("approvals:\n  mode: smart\n"))
        // Absent key = host default (smart/manual), never off.
        #expect(!Self.chip("model:\n  default: x\n"))
        // Quoted "no" is a string to PyYAML → `manual` to Hermes.
        #expect(!Self.chip("approvals:\n  mode: \"no\"\n"))
    }

    /// The value the chip used to look for is not a mode: Hermes warns and
    /// falls back to `manual`, so approvals are ON and the chip must stay
    /// hidden.
    @Test func strayYoloValueIsManualNotOff() {
        #expect(!Self.chip("approvals:\n  mode: yolo\n"))
    }

    /// C1: hosts below the chip's v0.14 gate render exactly as before.
    @Test func chipStaysGatedBelowV014() {
        #expect(!Self.chip("approvals:\n  mode: off\n", Self.v013))
    }

    /// End to end through the chat VM's own config refresh: a home whose
    /// config says `off` lands `.off` in `approvalMode`.
    @Test @MainActor func chatViewModelReadsTheNormalizedMode() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        try "model:\n  default: test-model\n  provider: anthropic\napprovals:\n  mode: false\n"
            .write(toFile: home.path + "/config.yaml", atomically: true, encoding: .utf8)
        let vm = ChatViewModel(context: home.context)
        vm.refreshConfigDiagnostics()
        let loaded = await Lifecycle.waitUntil { vm.approvalMode == .off }
        #expect(loaded, "approvalMode never became .off (got \(String(describing: vm.approvalMode)))")
    }

    // MARK: - S03-F4 rename off the main actor

    /// Thread-safe record of what the injected CLI runners saw.
    final class RunnerProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(id: String, title: String?, onMain: Bool)] = []
        func record(_ id: String, _ title: String?) {
            lock.lock(); defer { lock.unlock() }
            calls.append((id, title, Thread.isMainThread))
        }
        var all: [(id: String, title: String?, onMain: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    @Test @MainActor func renameRunsTheCLIOffTheMainActor() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let probe = RunnerProbe()
        vm.sessionRenameRunner = { _, id, title in
            probe.record(id, title)
            return ("", 0)
        }

        let ok = await vm.renameSession("sess-1", to: "  -dash first  ")
        #expect(ok)
        #expect(probe.all.count == 1)
        #expect(probe.all.first?.id == "sess-1")
        #expect(probe.all.first?.title == "-dash first")
        #expect(probe.all.first?.onMain == false, "sessions rename ran on the main thread (C10)")
        #expect(vm.renameError == nil)
        #expect(vm.isRenamingSession == false)
    }

    /// A refused rename keeps its reason for the sheet and reports failure.
    @Test @MainActor func refusedRenameSurfacesTheReason() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        vm.sessionRenameRunner = { _, _, _ in ("Error: session title 'Bot Chat' is reserved", 1) }

        let ok = await vm.renameSession("sess-1", to: "Bot Chat")
        #expect(!ok)
        #expect(vm.renameError != nil)
        #expect(vm.isRenamingSession == false)
    }

    /// An empty title never reaches the CLI.
    @Test @MainActor func emptyRenameIsANoOp() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let probe = RunnerProbe()
        vm.sessionRenameRunner = { _, id, title in probe.record(id, title); return ("", 0) }
        let ok = await vm.renameSession("sess-1", to: "   ")
        #expect(!ok)
        #expect(probe.all.isEmpty)
    }

    // MARK: - t-fa0043f6 delete off the main actor

    @Test @MainActor func deleteRunsTheCLIOffTheMainActor() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let vm = ChatViewModel(context: home.context)
        let probe = RunnerProbe()
        vm.sessionDeleteRunner = { _, id in
            probe.record(id, nil)
            return 0
        }
        await vm.deleteSession("sess-9")
        #expect(probe.all.map(\.id) == ["sess-9"])
        #expect(probe.all.first?.onMain == false, "sessions delete ran on the main thread (C10)")
    }
}
