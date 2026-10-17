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
