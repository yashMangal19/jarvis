import Foundation
import Testing
import JarvisCore

final class SessionTestClock: TimeSource {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class SessionTestSleepGuard: SleepGuard {
    private(set) var calls: [String] = []
    var held: Bool { calls.last == "hold" }
    func hold() { calls.append("hold") }
    func release() { calls.append("release") }
}

/// Today at hh:mm in the local zone — the zone gap markers are written in.
private func at(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
}

private let airPods = InputDevice(name: "AirPods Pro", isBluetoothHeadset: true)
private let builtIn = InputDevice(name: "MacBook Pro Microphone", isBluetoothHeadset: false)

@Suite struct ListeningSessionTests {
    let clock = SessionTestClock(at(14, 0))
    let sleepGuard = SessionTestSleepGuard()

    func makeSession(quiet: @escaping (Date) -> Bool = { _ in false }) -> ListeningSession {
        ListeningSession(clock: clock, sleepGuard: sleepGuard, isQuietTime: quiet)
    }

    @Test func airPodsDisconnectPausesAndReconnectResumesWithGapMarker() {
        let session = makeSession()
        session.start()
        session.handle(.inputChanged(airPods))

        clock.now = at(14, 5)
        session.handle(.inputLost(airPods))
        #expect(session.state == .paused(.routeLost))

        clock.now = at(14, 40)
        session.handle(.inputChanged(airPods))
        #expect(session.state == .listening)

        #expect(session.gapMarkers(in: DateInterval(start: at(14, 0), end: at(15, 0)))
                == ["14:05–14:40: not listening (AirPods disconnected)"])
    }

    @Test func userPauseComesBackAfterEveryAutomaticRule() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.pause(.user)

        session.handle(.inputChanged(airPods))
        quiet = true
        session.tick(now: at(22, 0))
        #expect(session.state == .stopped(.quietHours))
        quiet = false
        session.tick(now: at(7, 0))
        session.screenLocked()
        session.screenUnlocked()
        #expect(session.state == .paused(.user))

        session.resume()
        #expect(session.state == .listening)
    }

    @Test func userStopIsNotOverriddenByQuietHoursEnding() {
        var quiet = true
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.stop(.user)
        session.tick(now: at(22, 0))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .stopped(.user))
    }

    @Test func nonHeadsetRouteChangeOnlyMovesTheStatusLine() {
        let session = makeSession()
        session.start()
        session.handle(.inputChanged(airPods))
        #expect(session.statusLine == "Listening via AirPods Pro")

        session.handle(.inputChanged(builtIn))
        session.handle(.inputLost(builtIn))
        #expect(session.state == .listening)
        session.handle(.inputChanged(builtIn))
        #expect(session.statusLine == "Listening via MacBook Pro Microphone")
    }

    @Test func screenLockStopsAndUnlockRestoresWhatWasThere() {
        let session = makeSession()
        session.start()
        session.screenLocked()
        #expect(session.state == .stopped(.screenLock))
        session.screenUnlocked()
        #expect(session.state == .listening)

        session.pause(.voice)
        session.screenLocked()
        #expect(session.state == .stopped(.screenLock))
        session.screenUnlocked()
        #expect(session.state == .paused(.voice))
    }

    @Test func quietHoursStopAndRestartListening() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        quiet = true
        session.tick(now: at(22, 0))
        #expect(session.state == .stopped(.quietHours))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .listening)
    }

    @Test func quietHoursStopAVoicePauseWakeWordIncludedAndGiveItBack() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.pause(.voice)
        quiet = true
        session.tick(now: at(22, 0))
        #expect(session.state == .stopped(.quietHours))
        #expect(!session.wakeWordActive)
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .paused(.voice))
    }

    @Test func routeLossOutlivesQuietHoursUnlessTheHeadsetReturns() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.handle(.inputLost(airPods))
        quiet = true
        session.tick(now: at(22, 0))
        #expect(session.state == .stopped(.quietHours))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .paused(.routeLost))

        quiet = true
        session.tick(now: at(22, 0))
        session.handle(.inputChanged(airPods))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .listening)

        quiet = true
        session.tick(now: at(22, 0))
        session.handle(.inputLost(airPods))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .paused(.routeLost))
    }

    @Test func lockDuringQuietHoursRestoresThePreQuietState() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.pause(.user)
        quiet = true
        session.tick(now: at(22, 0))
        session.screenLocked()
        session.screenUnlocked()
        #expect(session.state == .stopped(.quietHours))
        session.screenLocked()
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .stopped(.screenLock))
        session.screenUnlocked()
        #expect(session.state == .paused(.user))
    }

    @Test func routeLossWhileLockedOutlivesAnUnlockDuringQuietHours() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.handle(.inputLost(airPods))
        session.screenLocked()
        quiet = true
        session.screenUnlocked()
        #expect(session.state == .stopped(.quietHours))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .paused(.routeLost))
    }

    @Test func lockTakesPrecedenceOverQuietHoursRestart() {
        var quiet = true
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.tick(now: at(22, 0))
        session.screenLocked()
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .stopped(.screenLock))
        session.screenUnlocked()
        #expect(session.state == .listening)
    }

    @Test func quietHoursStartingWhileLockedDoNotRestartListeningOnTheirEnd() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.screenLocked()
        quiet = true
        session.tick(now: at(22, 0))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .stopped(.screenLock))
    }

    @Test func unlockDuringQuietHoursWaitsForThemToEnd() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        session.start()
        session.screenLocked()
        quiet = true
        session.screenUnlocked()
        #expect(session.state == .stopped(.quietHours))
        quiet = false
        session.tick(now: at(7, 0))
        #expect(session.state == .listening)
    }

    @Test func airPodsBackWhileLockedResumesOnUnlock() {
        let session = makeSession()
        session.start()
        session.handle(.inputLost(airPods))
        session.screenLocked()
        session.handle(.inputChanged(airPods))
        session.screenUnlocked()
        #expect(session.state == .listening)
    }

    @Test func airPodsLostWhileLockedPausesOnUnlock() {
        let session = makeSession()
        session.start()
        session.handle(.inputChanged(airPods))
        clock.now = at(14, 10)
        session.screenLocked()
        session.handle(.inputLost(airPods))
        clock.now = at(14, 20)
        session.screenUnlocked()
        #expect(session.state == .paused(.routeLost))
        clock.now = at(14, 30)
        #expect(session.gapMarkers(in: DateInterval(start: at(14, 0), end: at(14, 30))) == [
            "14:10–14:20: not listening (screen locked)",
            "14:20–14:30: not listening (AirPods disconnected)",
        ])
    }

    @Test func everyNotListeningIntervalIsAMarkerClippedToTheWindow() {
        var quiet = false
        let session = makeSession(quiet: { _ in quiet })
        clock.now = at(13, 50)
        session.start()
        clock.now = at(13, 55)
        session.pause(.user)                 // 13:55–14:10 paused, clipped to 14:00
        clock.now = at(14, 10)
        session.resume()
        clock.now = at(14, 20)
        session.screenLocked()               // 14:20–14:30 screen locked
        clock.now = at(14, 30)
        session.screenUnlocked()
        quiet = true
        session.tick(now: at(14, 45))        // 14:45–14:50 quiet hours
        quiet = false
        session.tick(now: at(14, 50))
        clock.now = at(14, 55)
        session.stop(.user)                  // 14:55–open, clipped to 15:00
        clock.now = at(15, 30)

        #expect(session.gapMarkers(in: DateInterval(start: at(14, 0), end: at(15, 0))) == [
            "14:00–14:10: not listening (paused)",
            "14:20–14:30: not listening (screen locked)",
            "14:45–14:50: not listening (quiet hours)",
            "14:55–15:00: not listening (stopped)",
        ])
    }

    @Test func derivedPresentationFollowsTheState() {
        let session = makeSession()
        #expect(session.iconState == .greyPlain)
        #expect(session.statusLine == "Stopped")
        #expect(session.topMenuItem == "Start listening")
        #expect(!session.wakeWordActive && !session.storesMemory)

        session.start()
        #expect(session.iconState == .red)
        #expect(session.statusLine == "Listening")
        #expect(session.topMenuItem == "Pause listening")
        #expect(session.wakeWordActive && session.storesMemory)

        session.pause(.user)
        #expect(session.iconState == .greyDot)
        #expect(session.statusLine == "Paused")
        #expect(session.topMenuItem == "Resume")
        #expect(session.wakeWordActive && !session.storesMemory)

        session.screenLocked()
        #expect(session.iconState == .greyPlain)
        #expect(session.statusLine == "Stopped")
        #expect(!session.wakeWordActive && !session.storesMemory)
    }

    @Test func sleepGuardIsHeldExactlyWhileListening() {
        let session = makeSession()
        #expect(!sleepGuard.held)
        session.start()
        #expect(sleepGuard.held)
        session.pause(.user)
        #expect(!sleepGuard.held)
        session.resume()
        session.handle(.inputLost(airPods))
        #expect(!sleepGuard.held)
        session.handle(.inputChanged(airPods))
        #expect(sleepGuard.held)
        session.screenLocked()
        #expect(!sleepGuard.held)
        session.screenUnlocked()
        session.stop(.user)
        #expect(sleepGuard.calls == ["hold", "release", "hold", "release", "hold", "release", "hold", "release"])
    }
}
