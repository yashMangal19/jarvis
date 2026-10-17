import Testing
import JarvisCore

@Suite struct VoiceIntentParserTests {
    static let controls: [(String, VoiceIntent)] = [
        ("pause", .pause), ("pause listening", .pause),
        ("resume", .resume), ("resume listening", .resume),
        ("meeting mode on", .meetingMode(true)), ("meeting mode off", .meetingMode(false)),
        ("demo mode on", .demoMode(true)), ("demo mode off", .demoMode(false)),
        ("forget the last hour", .forgetLastHour), ("forget last hour", .forgetLastHour),
    ]

    // Story 8b: each control, bare and behind the wake word in the shapes transcription produces.
    @Test(arguments: controls)
    func everyControlParsesWithAndWithoutTheWakeWord(phrase: String, intent: VoiceIntent) {
        for heard in [phrase, "Jarvis, \(phrase)", "jarvis \(phrase)", "Hey Jarvis, \(phrase.capitalized).",
                      "JARVIS, please \(phrase.uppercased())!", "  Jarvis,  \(phrase)  please. "] {
            #expect(VoiceIntentParser.parse(heard) == intent, "\(heard)")
        }
    }

    @Test func dashesFromTranscriptionCountAsSpaces() {
        #expect(VoiceIntentParser.parse("Jarvis, demo-mode on.") == .demoMode(true))
    }

    // A control is the whole utterance; with anything more it is a tool command.
    @Test(arguments: ["pause the music", "resume the download", "Pause Spotify",
                      "turn meeting mode on in my calendar", "forget the last hour of the podcast"])
    func aControlWordInsideALongerCommandIsAToolCommand(heard: String) {
        #expect(VoiceIntentParser.parse("Jarvis, " + heard) == .toolCommand(heard))
    }

    @Test(arguments: ["What did Asha say about the budget?", "what was the standup about", "What do I owe Ravi?",
                      "When did we move the launch?", "Who said Thursday?", "Did I promise the deck?",
                      "Did we agree on pricing?", "Remind me what Ravi wanted"])
    func questionPrefixesAreMemoryQuestionsKeepingTheirWords(question: String) {
        #expect(VoiceIntentParser.parse("Jarvis, \(question)") == .memoryQuestion(question))
    }

    @Test func aQuestionPrefixMustBeWholeWords() {
        #expect(VoiceIntentParser.parse("Did Isha send it?") == .toolCommand("Did Isha send it?"))
    }

    @Test func toolCommandsKeepTheirCaseWithoutWakeWordOrFillers() {
        #expect(VoiceIntentParser.parse("Hey Jarvis, please email Asha the deck, please.")
                == .toolCommand("email Asha the deck"))
    }

    @Test(arguments: ["", "Jarvis", "Jarvis?", "hey jarvis, please", " , . "])
    func nothingLeftIsNoIntent(heard: String) {
        #expect(VoiceIntentParser.parse(heard) == nil)
    }
}
