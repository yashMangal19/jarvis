import CoreGraphics
import Foundation

/// Makes the capture streams `Jarvis` runs, one of each per instance. The live one opens real devices;
/// tests pass a fake, so the facade never touches a microphone or the screen.
public protocol SourceFactory {
    /// The active mic as chunks, and its 250 ms frames for the wake-word listener.
    func makeMic() -> (chunks: any AudioSourceStream, frames: AsyncStream<[Float]>)
    func makeSystemAudio() -> any AudioSourceStream
    func makeRoomMic() -> any AudioSourceStream
}

public struct LiveSourceFactory: SourceFactory {
    private let clock: any TimeSource

    public init(clock: any TimeSource = SystemClock()) {
        self.clock = clock
    }

    public func makeMic() -> (chunks: any AudioSourceStream, frames: AsyncStream<[Float]>) {
        let mic = MicSource(clock: clock)
        return (mic, mic.frames)
    }

    public func makeSystemAudio() -> any AudioSourceStream { SystemAudioSource(clock: clock) }
    public func makeRoomMic() -> any AudioSourceStream { RoomMicSource(clock: clock) }
}

/// Where audio-route changes come from: `AudioRouteMonitor` live, a fake in tests.
public protocol RouteEventSource: AnyObject {
    var onEvent: ((RouteEvent) -> Void)? { get set }
    /// The input in use now, if any.
    var current: InputDevice? { get }
}

extension AudioRouteMonitor: RouteEventSource {}

/// Whether the screen is locked right now, read once at launch (DEC-25); `ScreenLockObserving` only
/// reports changes.
public protocol ScreenLockState: AnyObject {
    var isScreenLocked: Bool { get }
}

extension DistributedScreenLockObserver: ScreenLockState {
    /// From the login session's dictionary. Ceiling: `CGSSessionScreenIsLocked` is not a documented key;
    /// if it ever goes away this reads `false`, and a launch while locked is caught at the next lock event.
    public var isScreenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
