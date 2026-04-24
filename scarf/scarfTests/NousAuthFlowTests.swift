import Testing
import Foundation
@testable import scarf

/// Unit tests for the pure parsers in ``NousAuthFlow``. The subprocess side
/// of the flow is covered by manual end-to-end testing against a live
/// hermes install — parser behavior is what we can pin here.
@Suite struct NousAuthFlowParserTests {

    // MARK: - Device-code block

    @Test func parsesVerificationURLAndUserCode() throws {
        let text = """
        Requesting device code from Nous Portal...

        To continue:
          1. Open: https://portal.nousresearch.com/device/ABCD-EFGH
          2. If prompted, enter code: ABCD-EFGH
        Waiting for approval (polling every 1s)...
        """
        let result = try #require(NousAuthFlow.parseDeviceCode(from: text))
        #expect(result.verificationURL.absoluteString == "https://portal.nousresearch.com/device/ABCD-EFGH")
        #expect(result.userCode == "ABCD-EFGH")
    }

    @Test func ignoresNoiseBetweenExpectedLines() throws {
        // Hermes may log unrelated diagnostics between or after the two
        // expected lines. The parser anchors on line-start regex so noise
        // above, below, or even intermixed shouldn't block it.
        let text = """
        [DEBUG] some internal log line
        To continue:
          1. Open: https://portal.nousresearch.com/device/WXYZ-1234
        [DEBUG] another log line
          2. If prompted, enter code: WXYZ-1234
        extra trailing noise
        """
        let result = try #require(NousAuthFlow.parseDeviceCode(from: text))
        #expect(result.userCode == "WXYZ-1234")
    }

    @Test func returnsNilWhenUserCodeLineMissing() {
        let text = """
        To continue:
          1. Open: https://portal.nousresearch.com/device/AAAA-AAAA
        Waiting for approval...
        """
        #expect(NousAuthFlow.parseDeviceCode(from: text) == nil)
    }

    @Test func returnsNilWhenURLLineMissing() {
        let text = """
        To continue:
          2. If prompted, enter code: BBBB-BBBB
        """
        #expect(NousAuthFlow.parseDeviceCode(from: text) == nil)
    }

    @Test func returnsNilOnEmptyInput() {
        #expect(NousAuthFlow.parseDeviceCode(from: "") == nil)
    }

    // MARK: - Subscription-required failure

    @Test func parsesSubscriptionRequiredBillingURL() throws {
        let text = """
        Login successful!

        Your Nous Portal account does not have an active subscription.
          Subscribe here: https://portal.nousresearch.com/billing

        After subscribing, run `hermes model` again to finish setup.
        """
        let url = try #require(NousAuthFlow.parseSubscriptionRequired(from: text))
        #expect(url.absoluteString == "https://portal.nousresearch.com/billing")
    }

    @Test func subscriptionRequiredReturnsNilWithoutMarker() {
        let text = """
        hermes: something else went wrong
        Subscribe here: https://example.com/billing
        """
        // The "Subscribe here:" URL alone isn't enough — we require the
        // specific subscription-required sentinel so we don't misclassify
        // unrelated errors as subscription failures.
        #expect(NousAuthFlow.parseSubscriptionRequired(from: text) == nil)
    }

    @Test func subscriptionRequiredReturnsNilWhenBillingURLMissing() {
        let text = """
        Your Nous Portal account does not have an active subscription.
        (no subscribe here line)
        """
        #expect(NousAuthFlow.parseSubscriptionRequired(from: text) == nil)
    }

    // MARK: - State equality

    @Test func stateEnumEquatableDistinguishesCases() {
        let u = URL(string: "https://example.com")!
        let a: NousAuthFlow.State = .waitingForApproval(userCode: "X", verificationURL: u)
        let b: NousAuthFlow.State = .waitingForApproval(userCode: "X", verificationURL: u)
        let c: NousAuthFlow.State = .waitingForApproval(userCode: "Y", verificationURL: u)
        #expect(a == b)
        #expect(a != c)
        #expect(NousAuthFlow.State.idle != NousAuthFlow.State.starting)
        #expect(NousAuthFlow.State.success != NousAuthFlow.State.failure(reason: "", billingURL: nil))
    }
}
