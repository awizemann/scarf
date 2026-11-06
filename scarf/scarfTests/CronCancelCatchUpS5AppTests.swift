import Testing
import Foundation
@testable import scarf
import ScarfCore

/// S5 — the app-target half: `--catch-up` argv gating and the cancel
/// messages. Flags walked at `hermes_cli/subcommands/cron.py:15-26, :55,
/// :130, :200-204` @ v0.23.0.
@MainActor
@Suite struct CronCancelCatchUpS5AppTests {
    final class Calls: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var _items: [[String]] = []
        func append(_ args: [String]) {
            os_unfair_lock_lock(&lock); _items.append(args); os_unfair_lock_unlock(&lock)
        }
        func first(_ prefix: [String]) -> [String]? {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return _items.first { Array($0.prefix(prefix.count)) == prefix }
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func run(_ body: (CronViewModel) -> Void, prefix: [String]) async throws -> [String] {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let calls = Calls()
        let vm = CronViewModel(context: home.context, mutationRunner: { args, _ in
            calls.append(args)
            return ("", 0)
        })
        body(vm)
        await Self.settle { calls.first(prefix) != nil }
        return try #require(calls.first(prefix))
    }

    private static func form(catchUp: Bool?) -> CronJobEditor.FormState {
        var form = CronJobEditor.FormState()
        form.name = "Nightly"
        form.schedule = "0 9 * * *"
        form.prompt = "summarize"
        form.catchUp = catchUp
        return form
    }

    private static func job(catchUp: Bool?) -> HermesCronJob {
        HermesCronJob(id: "job1", name: "Nightly", prompt: "summarize",
                      schedule: CronSchedule(kind: "cron", display: "0 9 * * *", expression: "0 9 * * *"),
                      enabled: true, state: "scheduled",
                      extra: catchUp.map { ["catch_up": .bool($0)] } ?? [:])
    }

    static let supported = CronViewModel.EditorSupport(catchUp: true)
    static let older = CronViewModel.EditorSupport()

    @Test func createPassesCatchUpOnlyWhenSupportedAndSet() async throws {
        let on = try await run({ $0.createJob(from: Self.form(catchUp: false), support: Self.supported) },
                               prefix: ["cron", "create"])
        let flag = try #require(on.firstIndex(of: "--catch-up=off"))
        #expect(flag < (on.firstIndex(of: "--") ?? .max))
        let unset = try await run({ $0.createJob(from: Self.form(catchUp: nil), support: Self.supported) },
                                  prefix: ["cron", "create"])
        #expect(!unset.contains { $0.hasPrefix("--catch-up") })
        let old = try await run({ $0.createJob(from: Self.form(catchUp: true), support: Self.older) },
                                prefix: ["cron", "create"])
        #expect(!old.contains { $0.hasPrefix("--catch-up") })
    }

    @Test func editSendsCatchUpOnlyOnChange() async throws {
        let changed = try await run({ $0.updateJob(Self.job(catchUp: true), from: Self.form(catchUp: false), support: Self.supported) },
                                    prefix: ["cron", "edit"])
        #expect(changed.contains("--catch-up=off"))
        let same = try await run({ $0.updateJob(Self.job(catchUp: true), from: Self.form(catchUp: true), support: Self.supported) },
                                 prefix: ["cron", "edit"])
        #expect(!same.contains { $0.hasPrefix("--catch-up") })
        let fromUnset = try await run({ $0.updateJob(Self.job(catchUp: nil), from: Self.form(catchUp: true), support: Self.supported) },
                                      prefix: ["cron", "edit"])
        #expect(fromUnset.contains("--catch-up=on"))
        let old = try await run({ $0.updateJob(Self.job(catchUp: true), from: Self.form(catchUp: false), support: Self.older) },
                                prefix: ["cron", "edit"])
        #expect(!old.contains { $0.hasPrefix("--catch-up") })
    }

    @Test func cancelRunSendsCancelArgv() async throws {
        let args = try await run({ $0.cancelRun(Self.job(catchUp: nil)) }, prefix: ["cron", "cancel"])
        #expect(args == ["cron", "cancel", "--", "job1"])
    }

    @Test func cancelMessagesDistinguishTheThreeOutcomes() {
        #expect(CronViewModel.cancelMessage(.cancelRequested, jobName: "N").outcome == .success)
        #expect(CronViewModel.cancelMessage(.nothingToCancel, jobName: "N").outcome == .unconfirmed)
        #expect(CronViewModel.cancelMessage(.failed("Failed to cancel run: x"), jobName: "N").outcome == .failure)
        #expect(CronViewModel.cancelMessage(.unrecognized, jobName: "N").outcome == .unconfirmed)
    }
}
