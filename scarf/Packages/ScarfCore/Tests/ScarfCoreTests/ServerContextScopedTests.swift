import Testing
import Foundation
@testable import ScarfCore

/// Coverage for `ServerContext.scoped(toProfile:)` — the Mac app's per-window
/// profile scoping seam (#126, the analogue of iOS Design B #120). Verifies
/// the `remoteHome` re-point that makes every derived `paths.*` (state.db,
/// sessions, memories, cron) follow the selected profile. Linux-safe.
@Suite struct ServerContextScopedTests {

    private func remote(remoteHome: String? = nil) -> ServerContext {
        ServerContext(
            id: ServerID(),
            displayName: "Remote",
            kind: .ssh(SSHConfig(host: "example", remoteHome: remoteHome))
        )
    }

    @Test func defaultSelectionLeavesRootHomeUntouched() {
        let ctx = remote(remoteHome: "~/.hermes")
        // nil / "default" / invalid all resolve to the base (no-op copy).
        for sel in [nil, "default", "Bad Name", "  "] as [String?] {
            let scoped = ctx.scoped(toProfile: sel)
            #expect(scoped.paths.home == "~/.hermes")
            #expect(scoped.paths.stateDB == "~/.hermes/state.db")
        }
    }

    @Test func namedProfileRepointsHomeAndStateDB() {
        let scoped = remote(remoteHome: "~/.hermes").scoped(toProfile: "work")
        #expect(scoped.paths.home == "~/.hermes/profiles/work")
        #expect(scoped.paths.stateDB == "~/.hermes/profiles/work/state.db")
    }

    @Test func usesDefaultRemoteHomeWhenNoneConfigured() {
        let scoped = remote(remoteHome: nil).scoped(toProfile: "work")
        #expect(scoped.paths.home == HermesPathSet.defaultRemoteHome + "/profiles/work")
    }

    @Test func customRootHomeIsHonored() {
        let scoped = remote(remoteHome: "/opt/data").scoped(toProfile: "work")
        #expect(scoped.paths.home == "/opt/data/profiles/work")
    }

    /// Re-selecting from an already-profile-scoped home resolves from the
    /// ROOT, never nesting `profiles/a/profiles/b`.
    @Test func reselectingDoesNotNestProfiles() {
        let alreadyScoped = remote(remoteHome: "~/.hermes/profiles/a")
        #expect(alreadyScoped.scoped(toProfile: "b").paths.home == "~/.hermes/profiles/b")
        #expect(alreadyScoped.scoped(toProfile: nil).paths.home == "~/.hermes")
    }

    /// Identity and display name are preserved across scoping.
    @Test func preservesIdentity() {
        let ctx = remote(remoteHome: "~/.hermes")
        let scoped = ctx.scoped(toProfile: "work")
        #expect(scoped.id == ctx.id)
        #expect(scoped.displayName == ctx.displayName)
        #expect(scoped.isRemote)
    }

    /// Local contexts have no `remoteHome` seam — scoping is a no-op there
    /// (local profiles resolve from `active_profile`).
    @Test func localContextIsUnchanged() {
        let local = ServerContext.local
        let scoped = local.scoped(toProfile: "work")
        #expect(scoped.paths.home == local.paths.home)
        #expect(!scoped.isRemote)
    }
}
