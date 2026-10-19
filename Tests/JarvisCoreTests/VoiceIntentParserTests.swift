import Testing
import JarvisCore

@Suite struct CommandInterpreterTests {
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
            #expect(CommandInterpreter.interpret(heard) == intent, "\(heard)")
        }
    }

    // J-021: a near miss of a control is never a tool command: Jarvis asks "did you mean …?". Every closest
    // control is a candidate; the router picks the one that would change something.
    @Test(arguments: [
        ("meeting mode of", [VoiceIntent.meetingMode(true), .meetingMode(false)]),
        ("meeting mod off", [.meetingMode(false)]),
        ("turn meeting mode off", [.meetingMode(false)]),
        ("meeting mode off now", [.meetingMode(false)]),
        ("demo mode onn", [.demoMode(true)]),
        ("pause listing", [.pause]),
        ("forget the last our", [.forgetLastHour]),
    ])
    func aNearMissOfAControlIsAskedAbout(heard: String, candidates: [VoiceIntent]) {
        #expect(CommandInterpreter.interpret("Jarvis, " + heard) == .didYouMean([candidates]), "\(heard)")
    }

    // J-027 (QA-22): a word that sounds like a control is asked about, however short; never sent to Claude.
    @Test(arguments: [("boss.", VoiceIntent.pause), ("pass", .pause), ("paws", .pause), ("rezoom", .resume),
                      ("re-zoom", .resume), ("meeting mode of", .meetingMode(false))])
    func aWordThatSoundsLikeAControlIsAskedAbout(heard: String, control: VoiceIntent) {
        guard case .didYouMean(let steps) = CommandInterpreter.interpret("Jarvis, " + heard) else {
            Issue.record("\(heard) was not asked about"); return
        }
        #expect(steps.count == 1 && steps[0].contains(control), "\(heard)")
    }

    // J-027: one word that is no control and sounds like none is not acted on, and never goes to Claude.
    @Test(arguments: ["cause", "presume", "hello", "thanks"])
    func oneUnknownWordIsUnclear(heard: String) {
        #expect(CommandInterpreter.interpret("Jarvis, " + heard) == .unclear)
    }

    // J-027 (QA-22): controls said one after another run in that order.
    @Test func controlsSaidOneAfterAnotherRunInOrder() {
        #expect(CommandInterpreter.interpret("pause, Jarvis, resume.") == .controls([.pause, .resume]))
        #expect(CommandInterpreter.interpret("Jarvis, meeting mode on and then demo mode on")
                == .controls([.meetingMode(true), .demoMode(true)]))
        #expect(CommandInterpreter.interpret("Jarvis, boss, Jarvis, resume") == .didYouMean([[.pause], [.resume]]))
    }

    /// Controls mixed with other words: only the controls are asked about; nothing goes to Claude.
    @Test func controlsMixedWithOtherWordsAreAskedAbout() {
        #expect(CommandInterpreter.interpret("Jarvis, pause, and email Asha the deck") == .didYouMean([[.pause]]))
    }

    @Test(arguments: ["stop", "cancel", "stop talking", "Stop!"])
    func stopOrCancelIsTheCancelControl(heard: String) {
        #expect(CommandInterpreter.interpret("Jarvis, " + heard) == .cancel)
    }

    /// Two words are enough for a tool command (Orc's call, DEC-54).
    @Test func twoWordsAreEnoughForAToolCommand() {
        #expect(CommandInterpreter.interpret("Jarvis, email Asha") == .toolCommand("email Asha"))
        #expect(CommandInterpreter.interpret("Jarvis, pause music") == .toolCommand("pause music"))
    }

    @Test func dashesFromTranscriptionCountAsSpaces() {
        #expect(CommandInterpreter.interpret("Jarvis, demo-mode on.") == .demoMode(true))
    }

    // A control is the whole utterance; with anything more it is a tool command.
    @Test(arguments: ["pause the music", "resume the download", "Pause Spotify",
                      "turn meeting mode on in my calendar", "forget the last hour of the podcast"])
    func aControlWordInsideALongerCommandIsAToolCommand(heard: String) {
        #expect(CommandInterpreter.interpret("Jarvis, " + heard) == .toolCommand(heard))
    }

    @Test(arguments: ["What did Asha say about the budget?", "what was the standup about", "What do I owe Ravi?",
                      "When did we move the launch?", "Who said Thursday?", "Did I promise the deck?",
                      "Did we agree on pricing?", "Remind me what Ravi wanted"])
    func questionPrefixesAreMemoryQuestionsKeepingTheirWords(question: String) {
        #expect(CommandInterpreter.interpret("Jarvis, \(question)") == .memoryQuestion(question))
    }

    @Test func aQuestionPrefixMustBeWholeWords() {
        #expect(CommandInterpreter.interpret("Did Isha send it?") == .toolCommand("Did Isha send it?"))
    }

    @Test func toolCommandsKeepTheirCaseWithoutWakeWordOrFillers() {
        #expect(CommandInterpreter.interpret("Hey Jarvis, please email Asha the deck, please.")
                == .toolCommand("email Asha the deck"))
    }

    @Test(arguments: ["", "Jarvis", "Jarvis?", "hey jarvis, please", " , . "])
    func nothingLeftIsNoIntent(heard: String) {
        #expect(CommandInterpreter.interpret(heard) == nil)
    }
}
