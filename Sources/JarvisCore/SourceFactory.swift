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
