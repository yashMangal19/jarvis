import Foundation

/// What an utterance after the wake word asks for.
public indirect enum VoiceIntent: Equatable {
    case pause, resume
    case meetingMode(Bool), demoMode(Bool)
    case forgetLastHour
    /// "Stop" or "cancel": stop talking, and cancel a read-back waiting for its yes (J-027).
    case cancel
    /// The question as heard, wake word and fillers removed, case kept.
    case memoryQuestion(String)
    /// The command as heard, wake word and fillers removed, case kept ("email Asha the deck").
    case toolCommand(String)
    /// Controls said one after another ("pause, Jarvis, resume"), run in that order (J-027).
    case controls([VoiceIntent])
    /// Controls Jarvis isn't sure of: one step per control said, each with its closest controls. Never sent to a
    /// command runner; Jarvis asks "did you mean …?" (J-021, J-027).
    case didYouMean([[VoiceIntent]])
    /// Too short or unclear to act on ("hello", "cause"); never sent to a runner. Jarvis says it didn't catch that.
    case unclear
}

/// The one owner of what an utterance means (J-027, DEC-54). No outcome falls through to a command runner by
/// default: an utterance reaches Claude only as a tool command of two words or more with nothing in it that is,
/// or sounds like, a control.
///
/// - A control matches by its words or by its sound: words are compared by a consonant skeleton with voiced and
///   unvoiced letters merged, so "boss" is "pause" and "of" is "off". A near match is asked about, never guessed
///   and never sent to Claude.
/// - The utterance is split at each "Jarvis", at sentence punctuation and at "and"/"then". Controls said one
///   after another run in that order. Controls mixed with anything else are asked about.
/// - A one-word control with more words in the same breath stays a tool command ("pause the music").
/// - Questions match on a leading phrase ("what did …"), because a question carries its own subject.
public enum CommandInterpreter {
    private static let controlList: [(phrase: String, intent: VoiceIntent)] = [
        ("pause", .pause), ("pause listening", .pause),
        ("resume", .resume), ("resume listening", .resume),
        ("meeting mode on", .meetingMode(true)), ("meeting mode off", .meetingMode(false)),
        ("demo mode on", .demoMode(true)), ("demo mode off", .demoMode(false)),
        ("forget the last hour", .forgetLastHour), ("forget last hour", .forgetLastHour),
        ("stop", .cancel), ("cancel", .cancel), ("stop talking", .cancel),
    ]
    private static let controls = Dictionary(controlList.map { ($0.phrase, $0.intent) }, uniquingKeysWith: { a, _ in a })
    private static let questionPrefixes = ["what did", "what was", "what do", "when did", "who said",
                                           "did i", "did we", "remind me what"]
    /// Dropped from the start of an utterance; only "please" is also dropped from the end.
    private static let leadingFillers: Set = ["jarvis", "hey", "please", "ok", "okay"]
    /// Where an utterance splits into segments, besides sentence punctuation.
    private static let separators: Set = ["jarvis", "and", "then"]

    /// The phrases recognition is biased toward (J-027): the wake word and every control.
    public static let vocabulary: [String] = ["Jarvis"] + controlList.map(\.phrase) + ["yes", "no"]

    /// `nil` when nothing is left once the wake word and fillers are removed ("Jarvis?").
    public static func interpret(_ utterance: String) -> VoiceIntent? {
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
        if questionPrefixes.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) { return .memoryQuestion(heard) }

        let steps = segments(of: heard).map(classify)
        if steps.allSatisfy({ $0 == nil }) {
            return key.split(separator: " ").count >= 2 ? .toolCommand(heard) : .unclear
        }
        let found = steps.compactMap { $0 }
        if steps.count == found.count, found.allSatisfy({ $0.exact }) {
            return found.count == 1 ? found[0].candidates[0] : .controls(found.map { $0.candidates[0] })
        }
        return .didYouMean(found.map(\.candidates))
    }

    /// The utterance's pieces, normalised: split at sentence punctuation and at "jarvis", "and", "then".
    static func segments(of heard: String) -> [String] {
        heard.components(separatedBy: CharacterSet(charactersIn: ".,;!?:")).flatMap { part -> [String] in
            var pieces: [[String]] = [[]]
            for word in normaliseHeard(part).split(separator: " ").map(String.init) {
                if separators.contains(word) { pieces.append([]) } else { pieces[pieces.count - 1].append(word) }
            }
            return pieces.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }
        }
        .filter { !$0.split(separator: " ").allSatisfy { leadingFillers.contains(String($0)) } }
    }

    /// A segment as a control: exact, or its closest controls when it is near one; nil when it is no control.
    private static func classify(_ segment: String) -> (exact: Bool, candidates: [VoiceIntent])? {
        if let control = controls[segment] { return (true, [control]) }
        return nearMisses(of: segment).map { (false, $0) }
    }
}

extension CommandInterpreter {
    /// The controls closest to `key`, or nil when none is close (see the type's doc).
    static func nearMisses(of key: String) -> [VoiceIntent]? {
        let words = key.split(separator: " ").map(String.init)
        var best = Int.max
        var found: [VoiceIntent] = []
        let heardSound = soundKey(key)
        for (phrase, intent) in controlList {
            let phraseWords = phrase.split(separator: " ").map(String.init)
            var distance = editDistance(key, phrase)
            if distance > allowance(phrase) { distance = Int.max }
            if heardSound == soundKey(phrase) { distance = min(distance, 1) }
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

    /// A phrase as it sounds, word boundaries ignored ("re zoom" is "resume"): letters to a consonant skeleton (J-027). Spellings of one sound are made one
    /// letter (ph→f, ck/q/hard c→k, soft c→s, x→ks), voiced and unvoiced pairs merge (b/p, d/t, g/k, v/f, z/s),
    /// vowels and h, w, y go, and repeats collapse: "boss" and "pause" are both "ps", "of" and "off" both "f".
    static func soundKey(_ phrase: String) -> String {
        phrase.split(separator: " ").map { word -> String in
            var s = word.lowercased().filter(\.isLetter)
            for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "k"), ("x", "ks"), ("ce", "se"), ("ci", "si"), ("cy", "sy")] {
                s = s.replacingOccurrences(of: from, with: to)
            }
            let merged: [Character: Character] = ["c": "k", "q": "k", "b": "p", "d": "t", "g": "k", "v": "f", "z": "s"]
            var out: [Character] = []
            for c in s {
                let c = merged[c] ?? c
                if "aeiouhwy".contains(c) { continue }
                if out.last != c { out.append(c) }
            }
            return String(out)
        }.joined()
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

/// The one rule for matching heard words, used by both `CommandInterpreter` (controls) and
/// `CommandSession` (yes/no replies). Lowercased, dashes to spaces, other punctuation removed,
/// whitespace collapsed: "Meeting-mode ON!" → "meeting mode on", "Go-ahead!" → "go ahead".
func normaliseHeard(_ text: String) -> String {
    let scalars = text.lowercased().unicodeScalars.compactMap { c -> Unicode.Scalar? in
        if c.properties.generalCategory == .dashPunctuation { return " " }
        return CharacterSet.punctuationCharacters.contains(c) ? nil : c
    }
    return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
