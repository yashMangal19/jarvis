/// A live source of `AudioChunk`s.
public protocol AudioSourceStream {
    func start(onChunk: @escaping (AudioChunk) -> Void) throws
    func stop()
    /// Ends the chunk being recorded now and delivers it through `onChunk`, so no chunk spans a
    /// listening boundary (DEC-24). Recording carries on into a new chunk.
    func cut()
}

extension AudioSourceStream {
    /// No cut of its own (`RoomMicSource`): the caller stops the stream at a boundary instead.
    public func cut() {}
}

public enum AudioError: Error, Equatable {
    /// Microphone access is not granted. Jarvis never asks from here; the app does (T-25).
    case permissionDenied
    /// No usable input device, or its format cannot be converted to 16 kHz mono.
    case noInput
    /// The default input already is the built-in mic, so the mic stream records the room; run only that.
    case redundantWithDefaultInput
}

/// Whether a mic stream that should be running is recording (J-007).
public enum MicHealth: Equatable, Sendable {
    /// Recording, or stopped on purpose.
    case ok
    /// The input went away (AirPods dropping) and restarts are being retried.
    case reconnecting
    /// Retries have gone on for a while without an input; they carry on in the background.
    case unavailable
}

/// A stream that can lose its input while running and says so (`MicSource`).
public protocol ReportsMicHealth: AnyObject {
    /// Set once, before the first start. Called on the stream's own queue when the health changes.
    var onHealth: ((MicHealth) -> Void)? { get set }
}

/// A stream that can stop itself after a route change (`RoomMicSource`), so its owner re-evaluates it.
public protocol StopsItself: AnyObject {
    var onStopped: (() -> Void)? { get set }
}
