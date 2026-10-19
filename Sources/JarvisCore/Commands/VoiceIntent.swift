import Foundation

/// What an utterance after the wake word asks for.
public indirect enum VoiceIntent: Equatable {
    case pause, resume
    case meetingMode(Bool), demoMode(Bool)
    case forgetLastHour
    /// The question as heard, wake word and fillers removed, case kept.
    case memoryQuestion(String)
    /// The command as heard, wake word and fillers removed, case kept ("email Asha the deck").
    case toolCommand(String)
    /// Close to a control but not it ("meeting mode of"): the closest controls, in the order of the control list.
    /// Never sent to a command runner; Jarvis asks "did you mean …?" (J-021, DEC-50).
    case didYouMean([VoiceIntent])
}

/// Turns heard text into a `VoiceIntent`.
///
/// The rule that keeps a tool command from being a control by accident: a built-in control matches
/// only when it is the **whole** utterance, once the wake word and fillers are gone. "Pause" and
/// "pause listening" pause Jarvis; "pause the music" is a tool command. Questions match on a leading
/// phrase ("what did …"), because a question carries its own subject.
///
/// The rule that keeps a control from being a tool command by accident (J-021): an utterance close to a
/// control is `.didYouMean`, never a tool command. Close means within a small edit distance (none for short
/// phrases, so "pass" is not "pause"), or a control of two or more words with one extra word ("turn meeting
/// mode off"). A one-word control with more words stays a tool command ("pause the music").
public enum VoiceIntentParser {
    private static let controlList: [(phrase: String, intent: VoiceIntent)] = [
        ("pause", .pause), ("pause listening", .pause),
        ("resume", .resume), ("resume listening", .resume),
        ("meeting mode on", .meetingMode(true)), ("meeting mode off", .meetingMode(false)),
        ("demo mode on", .demoMode(true)), ("demo mode off", .demoMode(false)),
        ("forget the last hour", .forgetLastHour), ("forget last hour", .forgetLastHour),
    ]
    private static let controls = Dictionary(controlList.map { ($0.phrase, $0.intent) }, uniquingKeysWith: { a, _ in a })
    private static let questionPrefixes = ["what did", "what was", "what do", "when did", "who said",
                                           "did i", "did we", "remind me what"]
    /// Dropped from the start of an utterance; only "please" is also dropped from the end.
    private static let leadingFillers: Set = ["jarvis", "hey", "please", "ok", "okay"]

    /// `nil` when nothing is left once the wake word and fillers are removed ("Jarvis?").
    public static func parse(_ utterance: String) -> VoiceIntent? {
        var words = utterance.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, normaliseHeard(first).isEmpty || leadingFillers.contains(normaliseHeard(first)) {
            words.removeFirst()
        }
        while let last = words.last, normaliseHeard(last).isEmpty || normaliseHeard(last) == "please" {
            words.removeLast()
        }
        let heard = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        let key = normaliseHeard(heard)
        guard !key.isEmpty else { return nil }
        if let control = controls[key] { return control }
        if let near = nearMisses(of: key) { return .didYouMean(near) }
        if questionPrefixes.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) { return .memoryQuestion(heard) }
        return .toolCommand(heard)
    }
}

extension VoiceIntentParser {
    /// The controls closest to `key`, or nil when none is close (see the type's doc).
    static func nearMisses(of key: String) -> [VoiceIntent]? {
        let words = key.split(separator: " ").map(String.init)
        var best = Int.max
        var found: [VoiceIntent] = []
        for (phrase, intent) in controlList {
            let phraseWords = phrase.split(separator: " ").map(String.init)
            var distance = editDistance(key, phrase)
            if distance > allowance(phrase) { distance = Int.max }
            if phraseWords.count >= 2, words.count == phraseWords.count + 1,
               words.indices.contains(where: { skip in
                   Array(words[..<skip] + words[(skip + 1)...]) == phraseWords
               }) {
                distance = min(distance, 1)
            }
            guard distance != Int.max else { continue }
            if distance < best { best = distance; found = [] }
            if distance == best, !found.contains(intent) { found.append(intent) }
        }
        return found.isEmpty ? nil : found
    }

    /// Edits allowed: none under 7 characters, one under 12, then two.
    private static func allowance(_ phrase: String) -> Int {
        phrase.count < 7 ? 0 : phrase.count < 12 ? 1 : 2
    }

    /// Levenshtein distance over characters.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}

/// The one rule for matching heard words, used by both `VoiceIntentParser` (controls) and
/// `CommandSession` (yes/no replies). Lowercased, dashes to spaces, other punctuation removed,
/// whitespace collapsed: "Meeting-mode ON!" → "meeting mode on", "Go-ahead!" → "go ahead".
func normaliseHeard(_ text: String) -> String {
    let scalars = text.lowercased().unicodeScalars.compactMap { c -> Unicode.Scalar? in
        if c.properties.generalCategory == .dashPunctuation { return " " }
        return CharacterSet.punctuationCharacters.contains(c) ? nil : c
    }
    return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
