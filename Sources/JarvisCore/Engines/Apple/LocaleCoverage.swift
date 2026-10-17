import Foundation

/// SpeechAnalyzer's locale rule, kept outside the Speech SDK guard so it is testable on any Mac.
/// Mirrors `SpeechTranscriber.supportedLocale(equivalentTo:)` as observed on macOS 27: any listed
/// region of the same language is equivalent ("hi-US" resolves to "hi_IN"); no such language, no match.
enum LocaleCoverage {
    /// True only if **every** preferred locale is covered — a mixed-language speaker needs one engine for all.
    static func coversAll(_ preferred: [Locale], in supported: [Locale]) -> Bool {
        preferred.allSatisfy { locale in
            supported.contains { $0.language.languageCode == locale.language.languageCode }
        }
    }
}
