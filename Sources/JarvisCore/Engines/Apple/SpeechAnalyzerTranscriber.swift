// Swift 6.2 ships with the macOS 26 SDK (Xcode 26); older toolchains lack SpeechAnalyzer even though
// the Speech module exists, so `canImport(Speech)` alone does not detect the API.
#if canImport(Speech) && compiler(>=6.2)
import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechAnalyzer (macOS 26+): transcription with no model download of our own.
/// Usable only when it supports **every** preferred locale (`LocaleCoverage`).
@available(macOS 26, *)
public struct SpeechAnalyzerTranscriber: Transcriber {
    public struct Unavailable: Error {}

    public let displayName = "Apple SpeechAnalyzer"
    private let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public static func isUsable(forPreferred locales: [Locale]) async -> Bool {
        LocaleCoverage.coversAll(locales, in: await supportedLocales())
    }

    public func transcribe(_ chunk: AudioChunk) async throws -> String {
        guard !chunk.samples.isEmpty,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { throw Unavailable() }
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        // Supported but not yet downloaded: the request is nil once the asset is installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Unavailable()
        }
        let buffer = try Self.buffer(from: chunk, in: format)

        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        do {
            if let end = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chunk's mono Float samples, converted to the format the analyzer asks for.
    private static func buffer(from chunk: AudioChunk, in target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: chunk.sampleRate, channels: 1),
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
            let converter = AVAudioConverter(from: sourceFormat, to: target)
        else { throw Unavailable() }
        source.frameLength = source.frameCapacity
        chunk.samples.withUnsafeBufferPointer { samples in
            source.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        }

        let capacity = AVAudioFrameCount((Double(chunk.samples.count) * target.sampleRate / chunk.sampleRate).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Unavailable() }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        return output
    }
}
#endif
