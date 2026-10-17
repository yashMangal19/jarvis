import CoreAudio
import Foundation

/// Follows the system's default input and reports `RouteEvent`s: `.inputChanged` when the default
/// moves to a present device, `.inputLost(previous)` when the previous default leaves the device list.
/// `onEvent` is called on a private serial queue.
public final class AudioRouteMonitor {
    public var onEvent: ((RouteEvent) -> Void)?
    public var current: InputDevice? { lock.lock(); defer { lock.unlock() }; return entry?.device }

    typealias Entry = (id: AudioDeviceID, device: InputDevice)
    private var entry: Entry?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "jarvis.audio-route")
    private var listener: AudioObjectPropertyListenerBlock?
    private static let watched = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]

    public init() {
        entry = Self.defaultInput()
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
        let events = Self.events(previous: entry, newDefault: next, present: present)
        entry = next.flatMap { present.contains($0.id) ? $0 : nil }
        lock.unlock()
        events.forEach { onEvent?($0) }
    }

    /// The events one refresh produces. A loss is reported before the change it causes.
    static func events(previous: Entry?, newDefault: Entry?, present: Set<AudioDeviceID>) -> [RouteEvent] {
        var events: [RouteEvent] = []
        if let previous, !present.contains(previous.id) { events.append(.inputLost(previous.device)) }
        if let next = newDefault, present.contains(next.id), next.id != previous?.id {
            events.append(.inputChanged(next.device))
        }
        return events
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
