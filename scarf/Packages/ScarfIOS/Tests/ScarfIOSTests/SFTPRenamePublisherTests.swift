#if canImport(Citadel)
import Testing
import Foundation
import ScarfCore
@testable import ScarfIOS

/// t-e2cd2861 (P8 DI-H1) — the Citadel publish fallback.
///
/// SFTP v3's rename fails when the destination exists, so a fallback that
/// displaces the destination is required. The old one displaced it on ANY
/// rename error, which on a phone means: link drops → the user's file is
/// DELETED → the retry fails too → nothing is left but a staged temp. These
/// tests pin the two proofs that now have to line up before the destination
/// is touched.
@Suite struct SFTPRenamePublisherTests {

    /// Records what the publisher did to the far side.
    final class Far: @unchecked Sendable {
        var renameAttempts = 0
        var destinationRemoved = false
        var stagedRemoved = false
        var destinationExists = true
        /// How many rename attempts fail before one succeeds. `Int.max`
        /// means every rename fails.
        var renameFailures = 0

        struct Failure: Error { let message: String }

        func rename() throws {
            renameAttempts += 1
            if renameFailures > 0 {
                renameFailures -= 1
                throw Failure(message: "sftp status 4")
            }
        }
    }

    private func publish(_ far: Far) async throws {
        try await SFTPRenamePublisher.publish(
            stagedPath: "/p/AGENTS.md.scarf-abc.tmp",
            reportPath: "/p/AGENTS.md",
            rename: { try far.rename() },
            destinationExists: { far.destinationExists },
            removeDestination: { far.destinationRemoved = true },
            removeStaged: { far.stagedRemoved = true }
        )
    }

    @Test func happyPathIsOneRenameAndTouchesNothingElse() async throws {
        let far = Far()
        try await publish(far)
        #expect(far.renameAttempts == 1)
        #expect(!far.destinationRemoved)
        #expect(!far.stagedRemoved)
    }

    /// A transient failure clears on the retry — and the destination is
    /// never touched. This is the shape that used to delete the file.
    @Test func aTransientRenameFailureIsRetriedWithoutTouchingTheDestination() async throws {
        let far = Far()
        far.renameFailures = 1
        try await publish(far)
        #expect(far.renameAttempts == 2)
        #expect(!far.destinationRemoved)
        #expect(!far.stagedRemoved)
    }

    /// A dead link: every rename fails and the destination cannot be
    /// proven to exist. The destination must be left EXACTLY as it was and
    /// the staged bytes named in the error, never removed.
    @Test func aDeadLinkLeavesTheDestinationIntactAndNamesTheStagedPath() async throws {
        let far = Far()
        far.renameFailures = .max
        far.destinationExists = false

        await #expect(throws: TransportError.self) { try await publish(far) }
        #expect(far.renameAttempts == 2, "retried once, then gave up without displacing anything")
        #expect(!far.destinationRemoved)
        #expect(!far.stagedRemoved)

        do {
            try await publish(far)
            Issue.record("expected a refusal")
        } catch let error as TransportError {
            #expect("\(error)".contains("AGENTS.md.scarf-abc.tmp"))
        }
    }

    /// The legitimate EEXIST case the fallback exists for: the destination
    /// is provably there, so it is displaced and the rename retried.
    @Test func aDestinationThatProvablyExistsIsDisplacedAndThenRenamedOver() async throws {
        let far = Far()
        far.renameFailures = 2  // the first attempt and the retry both fail
        far.destinationExists = true
        try await publish(far)
        #expect(far.destinationRemoved)
        #expect(far.renameAttempts == 3)
        #expect(!far.stagedRemoved)
    }

    /// If the destination can't be removed it is still intact, so the
    /// staged copy is redundant and gets cleared.
    @Test func aFailedDestinationRemovalClearsTheStagedCopy() async throws {
        let far = Far()
        far.renameFailures = .max
        far.destinationExists = true
        struct RemoveFailed: Error {}

        await #expect(throws: RemoveFailed.self) {
            try await SFTPRenamePublisher.publish(
                stagedPath: "/p/f.tmp",
                reportPath: "/p/f",
                rename: { try far.rename() },
                destinationExists: { far.destinationExists },
                removeDestination: { throw RemoveFailed() },
                removeStaged: { far.stagedRemoved = true }
            )
        }
        #expect(far.stagedRemoved)
    }

    /// The destination is gone and the staged file is the only copy of the
    /// new bytes: it must SURVIVE, named in the error.
    @Test func aFailedSecondRenameKeepsTheStagedBytes() async throws {
        let far = Far()
        far.renameFailures = .max
        far.destinationExists = true

        await #expect(throws: TransportError.self) { try await publish(far) }
        #expect(far.destinationRemoved)
        #expect(!far.stagedRemoved, "the staged file is the only copy of the new bytes")
    }
}
#endif
