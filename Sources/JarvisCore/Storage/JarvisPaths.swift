import Foundation

/// The data home's folder layout: plain files under one root.
public struct JarvisPaths {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Jarvis` for the current user. Not `~/Jarvis`: on a case-insensitive
    /// disk that is the same folder as a `~/jarvis` clone, and transcripts landed in its working tree (DEC-41).
    public static var standard: JarvisPaths {
        JarvisPaths(root: URL.applicationSupportDirectory.appending(path: "Jarvis"))
    }

    /// `~/Jarvis`, the data home before DEC-41; `adoptLegacyData(from:)` brings its files across once.
    public static var legacyRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Jarvis")
    }

    public var inbox: URL { root.appending(path: "inbox") }
    public var transcripts: URL { root.appending(path: "transcripts") }
    public var notesHourly: URL { root.appending(path: "notes/hourly") }
    public var notesDaily: URL { root.appending(path: "notes/daily") }
    public var notesWeekly: URL { root.appending(path: "notes/weekly") }
    public var index: URL { root.appending(path: "index") }
    public var prompts: URL { root.appending(path: "prompts") }
    public var models: URL { root.appending(path: "models") }
    public var imports: URL { root.appending(path: "imports") }
    public var settingsFile: URL { root.appending(path: "settings.json") }
    public var logs: URL { root.appending(path: "logs") }
    /// One line per voice command, kept like transcripts (J-016, DEC-47).
    public var commandLog: URL { logs.appending(path: "commands.jsonl") }

    /// Every folder of the layout, in one place.
    public var allFolders: [URL] {
        [inbox, transcripts, notesHourly, notesDaily, notesWeekly,
         index, prompts, models, imports, logs]
    }

    /// The top-level names Jarvis owns under `root`; nothing else is ever moved or copied.
    static let ownedNames = ["inbox", "transcripts", "notes", "index", "prompts", "models", "imports",
                             "logs", "settings.json"]

    public enum LayoutError: Error, LocalizedError {
        case insideGitRepository(URL)

        public var errorDescription: String? {
            switch self {
            case .insideGitRepository(let root):
                "its data folder \(root.path) is inside a git repository, where transcripts could be committed"
            }
        }
    }

    /// True when `url` or a folder above it, below `home`, holds a `.git` (a folder, or a file in a
    /// worktree). The walk stops before `home`, so a dotfiles repository at `~/.git` does not count.
    static func isInsideGitRepository(_ url: URL,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let stop = home.standardizedFileURL.path
        var folder = url.standardizedFileURL
        while folder.path != stop {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) { return true }
            if folder.pathComponents.count <= 1 { return false }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        return false
    }

    /// Creates every folder of the layout (and `root`); folders that already exist are left alone.
    /// Refuses a root inside a git repository, before creating anything.
    public func ensureLayout() throws {
        guard !Self.isInsideGitRepository(root) else { throw LayoutError.insideGitRepository(root) }
        for folder in allFolders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Brings the old data home's files across, once (until `root` holds the marker file). Each item
    /// Jarvis owns is brought only when `root` has none of that name, so the models the installer already
    /// put there stay. Items are moved, except out of a git repository (a `~/jarvis` clone on a
    /// case-insensitive disk): there they are copied and the originals left alone. A copy lands under a
    /// temporary name first, so an interrupted run leaves no half-copied item and the next launch carries on.
    /// Returns whether anything was brought across.
    @discardableResult
    public func adoptLegacyData(from old: URL) throws -> Bool {
        let fm = FileManager.default
        let marker = root.appending(path: ".adopted-legacy")
        guard old.standardizedFileURL.path != root.standardizedFileURL.path,
              !fm.fileExists(atPath: marker.path) else { return false }
        let copy = Self.isInsideGitRepository(old)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var brought = false
        for name in Self.ownedNames {
            let from = old.appending(path: name), to = root.appending(path: name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            if copy {
                let part = root.appending(path: name + ".part")
                try? fm.removeItem(at: part)
                try fm.copyItem(at: from, to: part)
                try fm.moveItem(at: part, to: to)
            } else {
                try fm.moveItem(at: from, to: to)
            }
            brought = true
        }
        try Data("\(old.path)\n".utf8).write(to: marker)
        return brought
    }
}
