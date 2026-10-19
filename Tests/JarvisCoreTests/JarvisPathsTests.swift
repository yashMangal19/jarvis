import Foundation
import Testing
@testable import JarvisCore

@Suite struct JarvisPathsTests {
    let fm = FileManager.default

    func scratch() -> URL { fm.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)") }

    func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    @Test func ensureLayoutCreatesAllNineDirectories() throws {
        let root = scratch()
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

    @Test func standardHomeIsApplicationSupportNotAFolderAClonePathCanMatch() {
        let root = JarvisPaths.standard.root.path
        #expect(root.hasSuffix("/Library/Application Support/Jarvis"))
        #expect(root.lowercased() != JarvisPaths.legacyRoot.path.lowercased())
    }

    @Test func ensureLayoutRefusesARootInsideAGitRepositoryAndCreatesNothing() throws {
        let clone = scratch()
        defer { try? fm.removeItem(at: clone) }
        try fm.createDirectory(at: clone.appending(path: ".git"), withIntermediateDirectories: true)
        let paths = JarvisPaths(root: clone)

        #expect(throws: JarvisPaths.LayoutError.self) { try paths.ensureLayout() }
        #expect(!fm.fileExists(atPath: paths.transcripts.path))

        let nested = JarvisPaths(root: clone.appending(path: "data/Jarvis"))
        #expect(throws: JarvisPaths.LayoutError.self) { try nested.ensureLayout() }
    }

    @Test func aWorktreeGitFileCountsAndTheHomeFolderItselfDoesNot() throws {
        let home = scratch()
        defer { try? fm.removeItem(at: home) }
        try write("gitdir: elsewhere", to: home.appending(path: "worktree/.git"))
        try fm.createDirectory(at: home.appending(path: ".git"), withIntermediateDirectories: true)

        #expect(JarvisPaths.isInsideGitRepository(home.appending(path: "worktree/Jarvis"), home: home))
        #expect(!JarvisPaths.isInsideGitRepository(home.appending(path: "Library/Jarvis"), home: home))
    }

    @Test func legacyDataInsideACloneIsCopiedAndTheOriginalsLeftAlone() throws {
        let base = scratch()
        defer { try? fm.removeItem(at: base) }
        let old = base.appending(path: "clone")
        try fm.createDirectory(at: old.appending(path: ".git"), withIntermediateDirectories: true)
        try write("room speech", to: old.appending(path: "transcripts/2026-10-19.jsonl"))
        try write("{}", to: old.appending(path: "settings.json"))
        try write("swift code", to: old.appending(path: "Sources/main.swift"))
        let paths = JarvisPaths(root: base.appending(path: "Application Support/Jarvis"))

        #expect(try paths.adoptLegacyData(from: old))

        #expect(try read(paths.transcripts.appending(path: "2026-10-19.jsonl")) == "room speech")
        #expect(try read(paths.settingsFile) == "{}")
        #expect(fm.fileExists(atPath: old.appending(path: "transcripts/2026-10-19.jsonl").path))
        #expect(fm.fileExists(atPath: old.appending(path: "settings.json").path))
        #expect(!fm.fileExists(atPath: paths.root.appending(path: "Sources").path))
        #expect(!fm.fileExists(atPath: paths.root.appending(path: ".git").path))
        try paths.ensureLayout()
    }

    @Test func legacyDataOutsideARepositoryIsMoved() throws {
        let base = scratch()
        defer { try? fm.removeItem(at: base) }
        let old = base.appending(path: "Jarvis")
        try write("# 14:00", to: old.appending(path: "notes/hourly/2026-10-19-14.md"))
        let paths = JarvisPaths(root: base.appending(path: "Application Support/Jarvis"))

        #expect(try paths.adoptLegacyData(from: old))

        #expect(try read(paths.notesHourly.appending(path: "2026-10-19-14.md")) == "# 14:00")
        #expect(!fm.fileExists(atPath: old.appending(path: "notes").path))
    }

    @Test func adoptionRunsOnceAndNeverReplacesWhatTheNewHomeHas() throws {
        let base = scratch()
        defer { try? fm.removeItem(at: base) }
        let old = base.appending(path: "Jarvis")
        try write("old", to: old.appending(path: "settings.json"))
        try write("old model", to: old.appending(path: "models/ggml-base.en.bin"))
        try write("# old note", to: old.appending(path: "notes/hourly/2026-10-18-09.md"))
        let paths = JarvisPaths(root: base.appending(path: "new"))
        try write("installer model", to: paths.models.appending(path: "ggml-small.bin"))

        #expect(try paths.adoptLegacyData(from: old))
        #expect(try read(paths.models.appending(path: "ggml-small.bin")) == "installer model")
        #expect(try read(paths.notesHourly.appending(path: "2026-10-18-09.md")) == "# old note")
        #expect(try read(paths.settingsFile) == "old")

        try fm.removeItem(at: paths.settingsFile)
        try write("again", to: old.appending(path: "settings.json"))
        #expect(try !paths.adoptLegacyData(from: old))
        #expect(!fm.fileExists(atPath: paths.settingsFile.path))
    }

    @Test func anInterruptedCopyIsRedoneAndLeavesNoPartFile() throws {
        let base = scratch()
        defer { try? fm.removeItem(at: base) }
        let old = base.appending(path: "clone")
        try fm.createDirectory(at: old.appending(path: ".git"), withIntermediateDirectories: true)
        try write("whole", to: old.appending(path: "transcripts/2026-10-19.jsonl"))
        let paths = JarvisPaths(root: base.appending(path: "new"))
        try write("half", to: paths.root.appending(path: "transcripts.part/2026-10-19.jsonl"))

        #expect(try paths.adoptLegacyData(from: old))

        #expect(try read(paths.transcripts.appending(path: "2026-10-19.jsonl")) == "whole")
        #expect(!fm.fileExists(atPath: paths.root.appending(path: "transcripts.part").path))
    }
}
