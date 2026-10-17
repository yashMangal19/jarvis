import Foundation

/// The ids Claude Code uses for `--allowedTools`. `Settings.default` contains none of them.
public enum ToolIDs {
    public static let shell = ["Bash"]
    public static let fileEdits = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
}

/// What the user chose in Settings, stored as `~/Jarvis/settings.json`.
public struct Settings: Codable, Equatable {
    /// The Claude Code tools the user ticked. Empty by default: shell and file edits stay off.
    public var allowedTools: [String]
    /// `nil` means no quiet hours.
    public var quietHours: QuietHours?

    public init(allowedTools: [String] = [], quietHours: QuietHours? = nil) {
        self.allowedTools = allowedTools
        self.quietHours = quietHours
    }

    public static let `default` = Settings()
}

/// A daily window in minutes from local midnight; it may cross midnight (22:00–07:00).
public struct QuietHours: Codable, Equatable {
    public var startMinutes: Int
    public var endMinutes: Int

    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let m = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        return startMinutes <= endMinutes ? (startMinutes..<endMinutes).contains(m)
                                          : (m >= startMinutes || m < endMinutes)
    }
}

/// Reads and writes `settings.json`.
public final class SettingsStore {
    private let paths: JarvisPaths

    public init(paths: JarvisPaths) {
        self.paths = paths
    }

    /// Missing file → defaults. Unreadable file → moved to `settings.json.bak`, defaults
    /// (never crash at launch).
    public func load() -> Settings {
        let file = paths.settingsFile
        guard let data = try? Data(contentsOf: file) else { return .default }
        if let settings = try? JSONDecoder().decode(Settings.self, from: data) { return settings }
        let bak = file.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: file, to: bak)
        return .default
    }

    /// Pretty-printed with sorted keys so the file stays hand-editable.
    public func save(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: paths.settingsFile, options: .atomic)
    }
}
