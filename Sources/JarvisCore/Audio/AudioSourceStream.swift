/// A live source of `AudioChunk`s. It does the device work and says when it stopped by itself; its owner,
/// `CaptureDriver`, decides everything else: restarts, health, what the menu says (J-020, DEC-49).
public protocol AudioSourceStream: AnyObject {
    func start(onChunk: @escaping (AudioChunk) -> Void) throws
    func stop()
    /// Set by the owner before the first `start`. Called, on the source's own queue, when the source stopped
    /// without `stop` being called: its device went away, or it would now duplicate another stream.
    var onStopped: ((SourceStop) -> Void)? { get set }
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

/// Why a source stopped by itself.
public enum SourceStop: Equatable, Sendable {
    /// Another stream records this audio now (the room mic once the built-in mic is the input): not a fault.
    case redundant
    /// Its device or stream failed or went away; the owner restarts it while it is wanted.
    case failed
}

/// Whether a source that should be running is recording, as its owner sees it (J-020).
public enum SourceHealth: Equatable, Sendable {
    /// Recording, or not wanted, or not a fault (no permission: that has its own menu line).
    case ok
    /// Not recording; restarts are being tried.
    case reconnecting
    /// Restarts have gone on a while without success; they carry on.
    case unavailable
}
