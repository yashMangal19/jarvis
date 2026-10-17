import Foundation
import Testing
import JarvisCore

@Suite struct SettingsStoreTests {
    private let fm = FileManager.default

    private func tempPaths() -> JarvisPaths {
        JarvisPaths(root: fm.temporaryDirectory.appending(path: "jarvis-\(UUID().uuidString)"))
    }

    @Test func loadOnEmptyRootReturnsDefaultsWithNoShellOrFileEditTool() {
        let paths = tempPaths()
        defer { try? fm.removeItem(at: paths.root) }

        let settings = SettingsStore(paths: paths).load()

        #expect(settings == Settings.default)
        #expect(settings.quietHours == nil)
        for tool in ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"] {
            #expect(!settings.allowedTools.contains(tool))
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        let paths = tempPaths()
        defer { try? fm.removeItem(at: paths.root) }
        let store = SettingsStore(paths: paths)
        let saved = Settings(allowedTools: ["mcp__calendar__list"],
                             quietHours: QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60))

        try store.save(saved)

        #expect(store.load() == saved)
    }

    @Test func freshSettingsFileHasEmptyAllowedTools() throws {
        let paths = tempPaths()
        defer { try? fm.removeItem(at: paths.root) }

        try SettingsStore(paths: paths).save(.default)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settingsFile))
        let allowed = (json as? [String: Any])?["allowedTools"] as? [Any]
        #expect(allowed != nil && allowed!.isEmpty)
    }

    @Test func quietHoursContainsWindowCrossingMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: hour, minute: minute))!
        }
        let night = QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)   // 22:00–07:00

        #expect(night.contains(at(22, 0), calendar: calendar))
        #expect(night.contains(at(23, 59), calendar: calendar))
        #expect(night.contains(at(0, 0), calendar: calendar))
        #expect(night.contains(at(6, 59), calendar: calendar))
        #expect(!night.contains(at(7, 0), calendar: calendar))
        #expect(!night.contains(at(12, 0), calendar: calendar))
        #expect(!night.contains(at(21, 59), calendar: calendar))

        let lunch = QuietHours(startMinutes: 12 * 60, endMinutes: 13 * 60)  // same-day window
        #expect(lunch.contains(at(12, 30), calendar: calendar))
        #expect(!lunch.contains(at(13, 0), calendar: calendar))
        #expect(!lunch.contains(at(23, 0), calendar: calendar))
    }

    @Test func corruptFileIsMovedToBakAndDefaultsReturned() throws {
        let paths = tempPaths()
        defer { try? fm.removeItem(at: paths.root) }
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: paths.settingsFile)

        let settings = SettingsStore(paths: paths).load()

        #expect(settings == Settings.default)
        let bak = paths.root.appending(path: "settings.json.bak")
        #expect(try Data(contentsOf: bak) == garbage)
        #expect(!fm.fileExists(atPath: paths.settingsFile.path))
    }
}
