#if canImport(Speech)
import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechAnalyzer (macOS 26+): transcription with no model download of our own.
/// Usable only when it supports **every** preferred locale — a mixed-language speaker needs one
/// engine for all of them, else selection falls back to whisper.
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

    public static func supports(
        _ locale: Locale,
        supportedLocales provider: () async -> [Locale] = supportedLocales
    ) async -> Bool {
        matches(locale, in: await provider())
    }

    public static func isUsable(
        forPreferred locales: [Locale],
        supportedLocales provider: () async -> [Locale] = supportedLocales
    ) async -> Bool {
        let supported = await provider()
        return locales.allSatisfy { matches($0, in: supported) }
    }

    /// Same language; same region too when the preferred locale names one ("hi" matches "hi-IN").
    private static func matches(_ locale: Locale, in supported: [Locale]) -> Bool {
        supported.contains {
            $0.language.languageCode == locale.language.languageCode
                && (locale.region == nil || $0.region == locale.region)
        }
    }

    public func transcribe(_ chunk: AudioChunk) async throws -> String {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
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
        if let end = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
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
