import Foundation

/// What an utterance after the wake word asks for.
public enum VoiceIntent: Equatable {
    case pause, resume
    case meetingMode(Bool), demoMode(Bool)
    case forgetLastHour
    /// The question as heard, wake word and fillers removed, case kept.
    case memoryQuestion(String)
    /// The command as heard, wake word and fillers removed, case kept ("email Asha the deck").
    case toolCommand(String)
}

/// Turns heard text into a `VoiceIntent`.
///
/// The rule that keeps a tool command from being a control by accident: a built-in control matches
/// only when it is the **whole** utterance, once the wake word and fillers are gone. "Pause" and
/// "pause listening" pause Jarvis; "pause the music" is a tool command. Questions match on a leading
/// phrase ("what did …"), because a question carries its own subject.
public enum VoiceIntentParser {
    private static let controls: [String: VoiceIntent] = [
        "pause": .pause, "pause listening": .pause,
        "resume": .resume, "resume listening": .resume,
        "meeting mode on": .meetingMode(true), "meeting mode off": .meetingMode(false),
        "demo mode on": .demoMode(true), "demo mode off": .demoMode(false),
        "forget the last hour": .forgetLastHour, "forget last hour": .forgetLastHour,
    ]
    private static let questionPrefixes = ["what did", "what was", "what do", "when did", "who said",
                                           "did i", "did we", "remind me what"]
    /// Dropped from the start of an utterance; only "please" is also dropped from the end.
    private static let leadingFillers: Set = ["jarvis", "hey", "please", "ok", "okay"]

    /// `nil` when nothing is left once the wake word and fillers are removed ("Jarvis?").
    public static func parse(_ utterance: String) -> VoiceIntent? {
        var words = utterance.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, normalise(first).isEmpty || leadingFillers.contains(normalise(first)) {
            words.removeFirst()
        }
        while let last = words.last, normalise(last).isEmpty || normalise(last) == "please" {
            words.removeLast()
        }
        let heard = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        let key = normalise(heard)
        guard !key.isEmpty else { return nil }
        if let control = controls[key] { return control }
        if questionPrefixes.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) { return .memoryQuestion(heard) }
        return .toolCommand(heard)
    }

    /// Lowercased, dashes to spaces, other punctuation removed, whitespace collapsed:
    /// "Meeting-mode ON!" → "meeting mode on". Same rule as `CommandSession`'s yes/no matching.
    static func normalise(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.compactMap { c -> Unicode.Scalar? in
            if c.properties.generalCategory == .dashPunctuation { return " " }
            return CharacterSet.punctuationCharacters.contains(c) ? nil : c
        }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
