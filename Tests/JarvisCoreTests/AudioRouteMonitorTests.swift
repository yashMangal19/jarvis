import Testing
@testable import JarvisCore

@Suite struct AudioRouteMonitorTests {
    private let airPods = (id: UInt32(70), device: InputDevice(name: "Test AirPods", isBluetoothHeadset: true))
    private let builtIn = (id: UInt32(80), device: InputDevice(name: "Test Built-in Mic", isBluetoothHeadset: false))

    @Test func removingTheDefaultHeadsetReportsItLostThenTheNewInput() {
        let events = AudioRouteMonitor.events(previous: airPods, newDefault: builtIn, present: [80])

        #expect(events.map(routeTestDescribe) == ["lost Test AirPods", "changed Test Built-in Mic"])
    }

    @Test func listChangingBeforeTheDefaultReportsTheLossOnce() {
        let first = AudioRouteMonitor.events(previous: airPods, newDefault: airPods, present: [80])
        let second = AudioRouteMonitor.events(previous: nil, newDefault: builtIn, present: [80])

        #expect(first.map(routeTestDescribe) == ["lost Test AirPods"])
        #expect(second.map(routeTestDescribe) == ["changed Test Built-in Mic"])
    }

    @Test func pickingAnotherInputWhileTheOldOneStaysIsOnlyAChange() {
        let events = AudioRouteMonitor.events(previous: builtIn, newDefault: airPods, present: [70, 80])

        #expect(events.map(routeTestDescribe) == ["changed Test AirPods"])
    }

    @Test func anUnchangedDefaultReportsNothing() {
        #expect(AudioRouteMonitor.events(previous: airPods, newDefault: airPods, present: [70, 80]).isEmpty)
    }
}

/// `RouteEvent` is not Equatable (its file belongs to T-5), so tests compare a readable form.
private func routeTestDescribe(_ event: RouteEvent) -> String {
    switch event {
    case .inputLost(let device): return "lost \(device.name)"
    case .inputChanged(let device): return "changed \(device.name)"
    }
}
