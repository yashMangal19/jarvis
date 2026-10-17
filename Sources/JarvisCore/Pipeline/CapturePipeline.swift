/// Turns one chunk into nothing (silent) or one labelled transcript line.
public final class CapturePipeline {
    public enum Outcome: Equatable {
        case dropped
        case empty
        case transcribed(TranscriptLine)
    }

    private let transcriber: any Transcriber
    private let store: TranscriptStore
    private let gate: SilenceGate

    public init(transcriber: any Transcriber, store: TranscriptStore, gate: SilenceGate = .init()) {
        self.transcriber = transcriber
        self.store = store
        self.gate = gate
    }

    /// This class neither keeps nor writes the chunk: it is only held for the duration of this call.
    public func process(_ chunk: AudioChunk) async throws -> Outcome {
        if gate.isSilent(chunk) { return .dropped }
        let text = TranscriptText.clean(try await transcriber.transcribe(chunk))
        if text.isEmpty { return .empty }
        let line = TranscriptLine(time: chunk.start, label: chunk.source.label, text: text)
        try store.append(line)
        return .transcribed(line)
    }
}
