import Foundation
import Testing
import JarvisCore

@Suite struct JarvisPathsTests {
    @Test func ensureLayoutCreatesAllNineDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        try JarvisPaths(root: root).ensureLayout()

        // Folder names are the spec's storage layout, not read back from JarvisPaths.
        let expected = ["inbox", "transcripts", "notes/hourly", "notes/daily", "notes/weekly",
                        "index", "prompts", "models", "imports"]
        for relative in expected {
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: root.appending(path: relative).path,
                                       isDirectory: &isDirectory)
            #expect(exists && isDirectory.boolValue, "\(relative) should exist as a directory")
        }
        #expect(JarvisPaths(root: root).settingsFile.path
                == root.appending(path: "settings.json").path)
    }
}
