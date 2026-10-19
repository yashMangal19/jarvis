import Testing
@testable import JarvisCore

/// J-027, DEC-55: what Jarvis said is aligned against what the mic heard, in order, and removed.
@Suite struct SpeechEchoTests {
    @Test func jarvisOwnSentenceIsRemovedWhole() {
        #expect(SpeechEcho.removing(["I will create a file called plan.txt."],
                                    from: "I will create a file called plan txt") == "")
    }

    @Test func whatTheUserSaidOverItSurvives() {
        let heard = "I will create a Jarvis stop file called plan txt"
        #expect(SpeechEcho.removing(["I will create a file called plan.txt."], from: heard) == "jarvis stop")
    }

    /// A sentence that names Jarvis cancels out only its own "Jarvis".
    @Test func onlyExtraJarvisesSurvive() {
        #expect(SpeechEcho.removing(["I am Jarvis."], from: "I am Jarvis") == "")
        #expect(SpeechEcho.removing(["I am Jarvis."], from: "I am Jarvis Jarvis pause") == "jarvis pause")
    }

    @Test func nothingSpokenLeavesTheTextAsHeard() {
        #expect(SpeechEcho.removing([], from: "Jarvis, Email Asha") == "Jarvis, Email Asha")
    }
}
