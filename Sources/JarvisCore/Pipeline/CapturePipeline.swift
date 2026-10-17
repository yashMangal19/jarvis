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
    private let forgotten: ForgottenWindows?

    public init(transcriber: any Transcriber, store: TranscriptStore, gate: SilenceGate = .init(),
                forgotten: ForgottenWindows? = nil) {
        self.transcriber = transcriber
        self.store = store
        self.gate = gate
        self.forgotten = forgotten
    }

    /// This class neither keeps nor writes the chunk: it is only held for the duration of this call.
    /// A line whose time the user forgot while it was transcribing is `.dropped`, never stored.
    public func process(_ chunk: AudioChunk) async throws -> Outcome {
        if gate.isSilent(chunk) { return .dropped }
        let text = TranscriptText.clean(try await transcriber.transcribe(chunk))
        if text.isEmpty { return .empty }
        let line = TranscriptLine(time: chunk.start, label: chunk.source.label, text: text)
        if let forgotten {
            guard try forgotten.unlessForgotten([line.time], { try store.append(line) }) != nil else { return .dropped }
        } else {
            try store.append(line)
        }
        return .transcribed(line)
    }
}
