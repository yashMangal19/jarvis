import Foundation

public enum PromptKind: String, CaseIterable {
    case hourly, daily, weekly, answer

    /// Seeded into `prompts/<kind>.md` on first read; after that the file is the user's.
    var defaultText: String {
        switch self {
        case .hourly:
            return """
            You are given one hour of a spoken transcript. Each line is "HH:MM Speaker: text", where \
            Speaker is Me (the user) or Others. Write a short Markdown note with exactly these sections:
            ## Topics
            ## Decisions
            ## To-dos
            ## People
            Use bullet points. Leave a section with "- none" when nothing fits. Do not invent anything \
            that is not in the transcript.
            """
        case .daily:
            return """
            You are given the hourly notes of one day. Write a Markdown summary of the day with the \
            sections ## Topics, ## Decisions, ## To-dos and ## People. Merge duplicates; keep it short.
            """
        case .weekly:
            return """
            You are given the daily notes of one week. Write a Markdown summary of the week with the \
            sections ## Topics, ## Decisions, ## To-dos and ## People. Merge duplicates; keep it short.
            """
        case .answer:
            return """
            Answer the question using only the notes provided. If the notes do not contain the answer, \
            say so. Answer in one or two sentences and name the hour or day the answer comes from.
            """
        }
    }
}

/// `prompts/<kind>.md`, editable by the user.
public struct PromptStore {
    private let paths: JarvisPaths

    public init(paths: JarvisPaths) {
        self.paths = paths
    }

    /// The prompt file's text, writing the default first if the file does not exist yet.
    public func prompt(_ kind: PromptKind) throws -> String {
        let file = paths.prompts.appending(path: "\(kind.rawValue).md")
        if FileManager.default.fileExists(atPath: file.path) {
            return try String(contentsOf: file, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: paths.prompts, withIntermediateDirectories: true)
        try kind.defaultText.write(to: file, atomically: true, encoding: .utf8)
        return kind.defaultText
    }

    /// Writes the default of every prompt file that does not exist yet, so all are editable early.
    public func seedDefaults() throws {
        for kind in PromptKind.allCases { _ = try prompt(kind) }
    }
}
