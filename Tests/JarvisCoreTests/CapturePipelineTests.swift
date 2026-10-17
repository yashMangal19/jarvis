import Foundation
import Testing
import JarvisCore

/// Answers every chunk with a scripted reply and counts the calls.
final class CapturePipelineFakeTranscriber: Transcriber {
    var reply: String
    private(set) var calls = 0

    init(reply: String = "Ship it Friday.") {
        self.reply = reply
    }

    func transcribe(_ chunk: AudioChunk) async throws -> String {
        calls += 1
        return reply
    }
}

@Suite struct CapturePipelineTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_792_000_000)
    let sampleRate = 16_000.0

    func makeStore() -> TranscriptStore {
        TranscriptStore(paths: JarvisPaths(root: root))
    }

    func everything(in store: TranscriptStore) throws -> [TranscriptLine] {
        try store.lines(in: DateInterval(start: start.addingTimeInterval(-60), duration: 120))
    }

    /// One second of digital silence.
    func silence(_ source: AudioSource = .mic) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: 0, count: Int(sampleRate)),
                   sampleRate: sampleRate, start: start, source: source)
    }

    /// One second of a 440 Hz sine at -20 dBFS RMS (peak 0.1 * sqrt(2)): ordinary speech level.
    func speech(_ source: AudioSource = .mic) -> AudioChunk {
        let peak = Float(0.1 * 2.0.squareRoot())
        let samples = (0..<Int(sampleRate)).map { i in
            peak * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate))
        }
        return AudioChunk(samples: samples, sampleRate: sampleRate, start: start, source: source)
    }

    // QA-7: a silent chunk is dropped before transcription and leaves no line.
    @Test func silentChunkIsDroppedWithoutCallingTheTranscriber() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = CapturePipelineFakeTranscriber()
        let store = makeStore()
        let pipeline = CapturePipeline(transcriber: transcriber, store: store)

        let outcome = try await pipeline.process(silence())

        #expect(outcome == .dropped)
        #expect(transcriber.calls == 0)
        #expect(try everything(in: store).isEmpty)
    }

    // Stories 4c, 12: the source decides the label; mic is "Me", system audio and room mic are "Others".
    @Test(arguments: [(AudioSource.mic, SpeakerLabel.me),
                      (.systemAudio, .others),
                      (.roomMic, .others)])
    func speechBecomesOneLineLabelledBySource(source: AudioSource, label: SpeakerLabel) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = CapturePipelineFakeTranscriber(reply: "Ship it Friday.")
        let store = makeStore()
        let pipeline = CapturePipeline(transcriber: transcriber, store: store)

        let outcome = try await pipeline.process(speech(source))

        let expected = TranscriptLine(time: start, label: label, text: "Ship it Friday.")
        #expect(outcome == .transcribed(expected))
        #expect(transcriber.calls == 1)
        #expect(try everything(in: store) == [expected])
    }

    // QA-9: whisper's placeholders and blank output are not speech and leave no line.
    @Test(arguments: ["[INAUDIBLE]", "[BLANK_AUDIO]", " [BLANK_AUDIO] [Music] ", "", "  \n "])
    func blankOrBracketOnlyOutputIsEmpty(reply: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = CapturePipelineFakeTranscriber(reply: reply)
        let store = makeStore()
        let pipeline = CapturePipeline(transcriber: transcriber, store: store)

        let outcome = try await pipeline.process(speech())

        #expect(outcome == .empty)
        #expect(try everything(in: store).isEmpty)
    }
}
