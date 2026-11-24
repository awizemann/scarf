import Testing
@testable import ScarfCore

/// B2: from v0.23.2 a graceful restart waits for idle with no upper bound
/// while the gateway keeps serving (`gateway/restart_when_idle.py`
/// `await_idle` @ v0.23.4); `agent.restart_after_turn_timeout` only spaces
/// out warnings. Scarf's watch must not give up while Hermes still waits.
@Suite struct GatewayRestartWhenIdleB2Tests {
    typealias Drain = HermesGatewayRestartDrain

    @Test func preIdleHostGivesUpAtBudgetPlusGraceEvenWhileDraining() {
        var d = Drain.WatchDeadline(budgetSeconds: 1815, graceSeconds: 120, waitsForIdle: false, now: 0)
        let e1 = d.expired(phase: .draining(work: nil), now: 1934)
        #expect(!e1)
        let e2 = d.expired(phase: .draining(work: nil), now: 1935)
        #expect(e2)
    }

    @Test func idleHostKeepsWatchingPastBudgetWhileDraining() {
        var d = Drain.WatchDeadline(budgetSeconds: 1815, graceSeconds: 120, waitsForIdle: true, now: 0)
        let e3 = d.expired(phase: .draining(work: ["chat turn"]), now: 10_000)
        #expect(!e3)
    }

    /// The idle wait ran past the budget, then the old gateway exited: the
    /// replacement still gets the grace to report in, not an instant give-up.
    @Test func idleHostGivesReplacementTheGraceAfterALongWait() {
        var d = Drain.WatchDeadline(budgetSeconds: 1815, graceSeconds: 120, waitsForIdle: true, now: 0)
        let e4 = d.expired(phase: .draining(work: nil), now: 5000)
        #expect(!e4)
        let e5 = d.expired(phase: .starting, now: 5100)
        #expect(!e5)
        let e6 = d.expired(phase: .starting, now: 5120)
        #expect(e6)
    }

    @Test func idleHostStillBoundedWhenDrainEndsEarly() {
        var d = Drain.WatchDeadline(budgetSeconds: 1815, graceSeconds: 120, waitsForIdle: true, now: 0)
        let e7 = d.expired(phase: .draining(work: nil), now: 30)
        #expect(!e7)
        let e8 = d.expired(phase: .starting, now: 1934)
        #expect(!e8)
        let e9 = d.expired(phase: .starting, now: 1935)
        #expect(e9)
    }

    @Test func copySaysChatsKeepWorkingOnlyOnIdleHosts() {
        #expect(Drain.drainingHeadline(waitsForIdle: true).contains("Chats keep working"))
        #expect(Drain.drainingHeadline(waitsForIdle: false)
                == "Waiting for the current turn to finish before restarting the gateway…")
        #expect(Drain.leftHeadline(waitsForIdle: false)
                == "Stopped watching. Hermes still restarts the gateway when the current turn ends.")
        #expect(Drain.leftHeadline(waitsForIdle: true).contains("once it's idle"))
    }
}
