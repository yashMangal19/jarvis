/// A live source of `AudioChunk`s.
public protocol AudioSourceStream {
    func start(onChunk: @escaping (AudioChunk) -> Void) throws
    func stop()
}

public enum AudioError: Error, Equatable {
    /// Microphone access is not granted. Jarvis never asks from here; the app does (T-25).
    case permissionDenied
    /// No usable input device, or its format cannot be converted to 16 kHz mono.
    case noInput
}
