import Testing
@testable import JarvisCore

@Suite struct AudioRouteMonitorTests {
    private let airPods = (id: UInt32(70), device: InputDevice(name: "Test AirPods", isBluetoothHeadset: true))
    private let builtIn = (id: UInt32(80), device: InputDevice(name: "Test Built-in Mic", isBluetoothHeadset: false))

    @Test func removingTheDefaultHeadsetReportsItLostThenTheNewInput() {
        var tracker = RouteTracker(current: airPods)

        let events = tracker.update(newDefault: builtIn, present: [80])

        #expect(events.map(routeTestDescribe) == ["lost Test AirPods", "changed Test Built-in Mic"])
    }

    @Test func theDefaultSwitchingBeforeTheHeadsetLeavesStillReportsTheHeadsetLostOnce() {
        var tracker = RouteTracker(current: airPods)

        let switched = tracker.update(newDefault: builtIn, present: [70, 80])
        let removed = tracker.update(newDefault: builtIn, present: [80])
        let later = tracker.update(newDefault: builtIn, present: [80])

        #expect(switched.map(routeTestDescribe) == ["changed Test Built-in Mic"])
        #expect(removed.map(routeTestDescribe) == ["lost Test AirPods"])
        #expect(later.isEmpty)
    }

    @Test func theHeadsetLeavingBeforeTheDefaultSwitchesReportsTheLossOnce() {
        var tracker = RouteTracker(current: airPods)

        let removed = tracker.update(newDefault: airPods, present: [80])
        let switched = tracker.update(newDefault: builtIn, present: [80])

        #expect(removed.map(routeTestDescribe) == ["lost Test AirPods"])
        #expect(switched.map(routeTestDescribe) == ["changed Test Built-in Mic"])
    }

    @Test func anUnchangedDefaultReportsNothing() {
        var tracker = RouteTracker(current: airPods)

        #expect(tracker.update(newDefault: airPods, present: [70, 80]).isEmpty)
    }
}

/// `RouteEvent` is not Equatable (its file belongs to T-5), so tests compare a readable form.
private func routeTestDescribe(_ event: RouteEvent) -> String {
    switch event {
    case .inputLost(let device): return "lost \(device.name)"
    case .inputChanged(let device): return "changed \(device.name)"
    }
}
