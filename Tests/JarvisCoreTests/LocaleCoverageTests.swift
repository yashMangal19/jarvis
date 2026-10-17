import Foundation
import Testing
@testable import JarvisCore

/// The SpeechAnalyzer locale rule, free of the Speech SDK, so it runs on any Mac.
@Suite struct LocaleCoverageTests {
    private static let enIN = Locale(identifier: "en-IN")
    private static let hiIN = Locale(identifier: "hi-IN")

    @Test func notCoveredWhenAnyPreferredLanguageIsMissing() {
        #expect(LocaleCoverage.coversAll([Self.enIN, Self.hiIN], in: [Self.enIN]) == false)
    }

    @Test func coveredWhenEveryPreferredLanguageIsListed() {
        #expect(LocaleCoverage.coversAll([Self.enIN, Locale(identifier: "hi")], in: [Locale(identifier: "en-US"), Self.hiIN]))
    }

    /// Matches `SpeechTranscriber.supportedLocale(equivalentTo:)`, which maps "hi-US" to "hi_IN" on macOS 27.
    @Test func coveredByAnotherRegionOfTheSameLanguage() {
        #expect(LocaleCoverage.coversAll([Self.enIN], in: [Locale(identifier: "en-US")]))
    }
}
