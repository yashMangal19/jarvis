import Foundation

/// The `~/Jarvis` folder layout: plain files under one root.
public struct JarvisPaths {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Jarvis` for the current user.
    public static var standard: JarvisPaths {
        JarvisPaths(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Jarvis"))
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

    /// Every folder of the layout, in one place.
    public var allFolders: [URL] {
        [inbox, transcripts, notesHourly, notesDaily, notesWeekly,
         index, prompts, models, imports]
    }

    /// Creates every folder of the layout (and `root`); folders that already exist are left alone.
    public func ensureLayout() throws {
        for folder in allFolders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}
