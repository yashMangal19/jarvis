// Same guard as SpeechAnalyzerTranscriber: Swift 6.2 ships with the macOS 26 SDK.
#if canImport(Speech) && compiler(>=6.2)
import Foundation
import Testing
@testable import JarvisCore
import AVFoundation
import Speech

@Suite struct SpeechAnalyzerTranscriberTests {
    @available(macOS 26, *)
    @Test func emptyChunkThrowsUnavailable() async {
        let chunk = AudioChunk(samples: [], sampleRate: 16_000, start: Date(), source: .mic)
        await #expect(throws: SpeechAnalyzerTranscriber.Unavailable.self) {
            try await SpeechAnalyzerTranscriber(locale: Locale(identifier: "en-US")).transcribe(chunk)
        }
    }

    @available(macOS 26, *)
    @Test func unsupportedLocaleThrowsUnavailable() async {
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, start: Date(), source: .mic)
        await #expect(throws: SpeechAnalyzerTranscriber.Unavailable.self) {
            try await SpeechAnalyzerTranscriber(locale: Locale(identifier: "sw")).transcribe(chunk)
        }
    }

    private static let sample = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".agentic/jarvis-ambient-memory/evidence/airpods3.wav")

    /// Smoke: real on-device transcription; skipped unless macOS 26+ with the English asset installed.
    private static func canSmoke() async -> Bool {
        guard FileManager.default.fileExists(atPath: sample.path) else { return false }
        if #available(macOS 26, *) {
            return await SpeechTranscriber.installedLocales.contains { $0.language.languageCode == "en" }
        }
        return false
    }

    @available(macOS 26, *)
    @Test(.enabled("macOS 26+, English SpeechTranscriber asset installed, sample present") { await canSmoke() })
    func transcribesEnglishSample() async throws {
        let file = try AVAudioFile(forReading: Self.sample)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let chunk = AudioChunk(samples: samples, sampleRate: file.processingFormat.sampleRate, start: Date(), source: .mic)

        let text = try await SpeechAnalyzerTranscriber(locale: Locale(identifier: "en-US")).transcribe(chunk)
        #expect(text.split(separator: " ").count >= 5)
    }

    /// J-027: the analyzer is given the wake word and the controls as contextual strings.
    @available(macOS 26, *)
    @Test func theAnalysisContextCarriesTheControlVocabulary() {
        let context = SpeechAnalyzerTranscriber.analysisContext(for: CommandInterpreter.vocabulary)
        #expect(context.contextualStrings[.general] == CommandInterpreter.vocabulary)
        #expect(CommandInterpreter.vocabulary.contains("Jarvis") && CommandInterpreter.vocabulary.contains("pause"))
    }
}
#endif
