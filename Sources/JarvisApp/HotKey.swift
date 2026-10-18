import Carbon

/// ⌥Space as a system-wide hot key with press and release (story 25a). A Carbon hot key needs no
/// Accessibility permission. `nil` when `InstallEventHandler` or `RegisterEventHotKey` returns anything but
/// `noErr`; `Triggers` then shows it in the menu. The registration is not exclusive (options 0), and
/// `eventHotKeyExistsErr` is returned only when both registrations pass `kEventHotKeyExclusive` (CarbonEvents.h),
/// so a clash with another app's hot key or a system shortcut is not reported: which one gets ⌥Space is macOS's.
@MainActor
final class HotKey {
    private let pressed: () -> Void
    private let released: () -> Void
    private var down = false

    init?(pressed: @escaping () -> Void, released: @escaping () -> Void) {
        self.pressed = pressed
        self.released = released
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        var handler: EventHandlerRef?
        // Passed unretained: `Triggers` keeps this object for the life of the process.
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, me in
            guard let event, let me else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(me).takeUnretainedValue()
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // The application event target is dispatched on the main thread.
            MainActor.assumeIsolated { hotKey.handle(isPress: isPress) }
            return noErr
        }, types.count, &types, me, &handler) == noErr else { return nil }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4A525653) /* "JRVS" */, id: 1)
        guard RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
                == noErr else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    /// `down` drops a repeated press, so one hold is one command.
    private func handle(isPress: Bool) {
        guard isPress != down else { return }
        down = isPress
        isPress ? pressed() : released()
    }
}
