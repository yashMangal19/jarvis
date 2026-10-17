import CoreAudio
import Foundation

/// Follows the system's default input and reports `RouteEvent`s: `.inputChanged` when the default
/// moves to a present device, `.inputLost(device)` when the previous default, or the last Bluetooth
/// headset that was the default, leaves the device list. `onEvent` is called on a private serial queue.
public final class AudioRouteMonitor {
    public var onEvent: ((RouteEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); handler = newValue; lock.unlock() }
    }
    public var current: InputDevice? { lock.lock(); defer { lock.unlock() }; return tracker.current?.device }

    typealias Entry = (id: AudioDeviceID, device: InputDevice)
    private var tracker: RouteTracker
    private var handler: ((RouteEvent) -> Void)?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "jarvis.audio-route")
    private var listener: AudioObjectPropertyListenerBlock?
    private static let watched = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]

    public init() {
        tracker = RouteTracker(current: Self.defaultInput())
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        self.listener = listener
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    deinit {
        guard let listener else { return }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    private func refresh() {
        let present = Set(Self.deviceIDs())
        let next = Self.defaultInput()
        lock.lock()
        let events = tracker.update(newDefault: next, present: present)
        let handler = handler
        lock.unlock()
        events.forEach { handler?($0) }
    }

    // MARK: CoreAudio reads

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInput() -> Entry? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &id),
              id != kAudioObjectUnknown else { return nil }
        var name: Unmanaged<CFString>?
        guard read(id, kAudioObjectPropertyName, into: &name), let name else { return nil }
        var transport: UInt32 = 0
        _ = read(id, kAudioDevicePropertyTransportType, into: &transport)
        return (id, InputDevice(name: name.takeRetainedValue() as String,
                                isBluetoothHeadset: transport == kAudioDeviceTransportTypeBluetooth
                                    || transport == kAudioDeviceTransportTypeBluetoothLE))
    }
}

/// The route rules, pure: what the previous state and one CoreAudio read imply.
/// CoreAudio does not order its default-input and device-list notifications, so a headset that was
/// the default is remembered until it leaves the list, even if the default has moved off it by then.
struct RouteTracker {
    typealias Entry = AudioRouteMonitor.Entry
    private(set) var current: Entry?
    private var headset: Entry?

    init(current: Entry?) {
        self.current = current
        headset = current.flatMap { $0.device.isBluetoothHeadset ? $0 : nil }
    }

    /// The events one refresh produces. A loss is reported before the change it causes, and once.
    mutating func update(newDefault: Entry?, present: Set<AudioDeviceID>) -> [RouteEvent] {
        var events: [RouteEvent] = []
        if let previous = current, !present.contains(previous.id) { events.append(.inputLost(previous.device)) }
        if let headset, headset.id != current?.id, !present.contains(headset.id) {
            events.append(.inputLost(headset.device))
        }
        if let next = newDefault, present.contains(next.id), next.id != current?.id {
            events.append(.inputChanged(next.device))
        }
        current = newDefault.flatMap { present.contains($0.id) ? $0 : nil }
        if let current, current.device.isBluetoothHeadset {
            headset = current
        } else if let gone = headset, !present.contains(gone.id) {
            headset = nil
        }
        return events
    }
}
