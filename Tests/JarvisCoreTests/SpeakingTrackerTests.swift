import Foundation
import Testing
@testable import JarvisCore

/// T-27 F-3, D-8: Jarvis counts as speaking until its last queued sentence ends, and never longer than
/// `SpeakingTracker.timeout` after the latest one began, so a lost finish callback cannot mute the wake word
/// for the rest of the session.
@Suite struct SpeakingTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func speakingLastsUntilTheLastQueuedSentenceEnds() {
        var tracker = SpeakingTracker()
        #expect(!tracker.isSpeaking)

        tracker.begin(now: t0)
        tracker.begin(now: t0)
        tracker.end()
        #expect(tracker.isSpeaking)
        tracker.end()
        #expect(!tracker.isSpeaking)
    }

    @Test func anEndWithNothingQueuedIsIgnored() {
        var tracker = SpeakingTracker()
        tracker.end()
        tracker.begin(now: t0)
        #expect(tracker.isSpeaking)
        tracker.end()
        #expect(!tracker.isSpeaking)
    }

    @Test func aLostFinishIsClearedOnceTheTimeoutHasPassedSinceTheLatestSentence() {
        var tracker = SpeakingTracker()
        tracker.begin(now: t0)
        tracker.begin(now: t0 + 60)

        tracker.expire(now: t0 + SpeakingTracker.timeout)
        #expect(tracker.isSpeaking)
        tracker.expire(now: t0 + 60 + SpeakingTracker.timeout)
        #expect(!tracker.isSpeaking)

        tracker.begin(now: t0 + 500)
        tracker.end()
        #expect(!tracker.isSpeaking)
    }

    @Test func resetClearsEverythingQueued() {
        var tracker = SpeakingTracker()
        tracker.begin(now: t0)
        tracker.begin(now: t0)
        tracker.reset()
        #expect(!tracker.isSpeaking)
        tracker.begin(now: t0)
        tracker.end()
        #expect(!tracker.isSpeaking)
    }
}
