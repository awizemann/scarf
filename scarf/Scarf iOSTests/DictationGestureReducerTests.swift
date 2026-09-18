import Testing
import Foundation
@testable import scarf_mobile

/// P1 fix (t-0fbb1c3c): `ChatView.dictationGesture` used to start a
/// take on the sequenced gesture's `.first` event, which fires at
/// touch-down — before the 0.2s long press has actually succeeded. A
/// quick tap or a VoiceOver double-tap fails that long press outright,
/// and SwiftUI never calls `.onEnded` for a gesture that failed to
/// recognize, so the take (and the mic) never stopped. These tests pin
/// `DictationGestureReducer`, the pure decision logic `dictationGesture`
/// now delegates to, against exactly that regression.
@Suite struct DictationGestureReducerTests {

    private typealias State = DictationGestureReducer.State
    private let cancelDistance: CGFloat = 60

    // MARK: - The core regression

    /// The bug: touch-down (`.first`, reported here as
    /// `longPressSucceeded: nil` since it never reaches `.second`) must
    /// never begin a take by itself.
    @Test func touchDownAloneNeverBeginsATake() {
        let (state, action) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: nil,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        #expect(action == .none)
        #expect(state.holdStarted == false)
    }

    /// A quick tap: touch-down, then release before the long press
    /// threshold — the long press fails, so `.second` is never reached.
    /// Even if `.onEnded` happens to run anyway, nothing should have
    /// started, so nothing needs to be released/stopped.
    @Test func quickTapNeverStartsOrReleasesATake() {
        let (afterTouchDown, downAction) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: nil,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        #expect(downAction == .none)

        let (finalState, shouldRelease) = DictationGestureReducer.onEnded(state: afterTouchDown)
        #expect(shouldRelease == false)
        #expect(finalState == State())
    }

    /// The success path: `.second(true, _)` is the only event that
    /// begins a take, and only the first time it's seen.
    @Test func longPressSuccessBeginsATakeExactlyOnce() {
        let (state1, action1) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: true,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        #expect(action1 == .begin)
        #expect(state1.holdStarted)

        // A second `.second(true, _)` update (e.g. the drag value
        // ticking with no meaningful movement) must not begin again.
        let (state2, action2) = DictationGestureReducer.onChanged(
            state: state1,
            longPressSucceeded: true,
            dragTranslation: CGSize(width: 1, height: 1),
            cancelDistance: cancelDistance
        )
        #expect(action2 == .none)
        #expect(state2.holdStarted)
    }

    @Test func holdThenReleaseWithinCancelRadiusReleasesTheTake() {
        let (started, _) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: true,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        let (finalState, shouldRelease) = DictationGestureReducer.onEnded(state: started)
        #expect(shouldRelease)
        #expect(finalState == State())
    }

    // MARK: - Drag-away cancel

    @Test func dragPastCancelDistanceCancelsTheTake() {
        let (started, _) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: true,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        let (cancelled, action) = DictationGestureReducer.onChanged(
            state: started,
            longPressSucceeded: true,
            dragTranslation: CGSize(width: 80, height: 0),
            cancelDistance: cancelDistance
        )
        #expect(action == .cancel)
        #expect(cancelled.cancelledByDrag)

        // Further movement after the cancel must not cancel again.
        let (stillCancelled, noAction) = DictationGestureReducer.onChanged(
            state: cancelled,
            longPressSucceeded: true,
            dragTranslation: CGSize(width: 200, height: 0),
            cancelDistance: cancelDistance
        )
        #expect(noAction == .none)
        #expect(stillCancelled.cancelledByDrag)
    }

    @Test func dragWithinCancelRadiusDoesNotCancel() {
        let (started, _) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: true,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        let (result, action) = DictationGestureReducer.onChanged(
            state: started,
            longPressSucceeded: true,
            dragTranslation: CGSize(width: 10, height: 10),
            cancelDistance: cancelDistance
        )
        #expect(action == .none)
        #expect(result.cancelledByDrag == false)
    }

    @Test func onEndedAfterDragCancelDoesNotAlsoRelease() {
        let (started, _) = DictationGestureReducer.onChanged(
            state: State(),
            longPressSucceeded: true,
            dragTranslation: nil,
            cancelDistance: cancelDistance
        )
        let (cancelled, _) = DictationGestureReducer.onChanged(
            state: started,
            longPressSucceeded: true,
            dragTranslation: CGSize(width: 80, height: 0),
            cancelDistance: cancelDistance
        )
        let (finalState, shouldRelease) = DictationGestureReducer.onEnded(state: cancelled)
        #expect(shouldRelease == false)
        #expect(finalState == State())
    }

    // MARK: - Every path resets on `.onEnded`

    @Test func onEndedAlwaysResetsStateForTheNextGestureCycle() {
        for state in [
            State(),
            State(holdStarted: true, cancelledByDrag: false),
            State(holdStarted: true, cancelledByDrag: true),
        ] {
            let (finalState, _) = DictationGestureReducer.onEnded(state: state)
            #expect(finalState == State())
        }
    }
}
