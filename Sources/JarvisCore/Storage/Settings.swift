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
    /// Jarvis has explained Screen Recording and asked for it; it never asks again (DEC-28).
    public var screenRecordingAsked: Bool

    public init(allowedTools: [String] = [], quietHours: QuietHours? = nil, screenRecordingAsked: Bool = false) {
        self.allowedTools = allowedTools
        self.quietHours = quietHours
        self.screenRecordingAsked = screenRecordingAsked
    }

    public static let `default` = Settings()

    /// A missing key falls back to its default, so a hand edit that drops one keeps the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        screenRecordingAsked = try c.decodeIfPresent(Bool.self, forKey: .screenRecordingAsked) ?? false
    }
}

/// A daily window in minutes from local midnight; it may cross midnight (22:00–07:00).
/// `startMinutes == endMinutes` is an empty window: never quiet.
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

    /// When the window holding `date` ends; `nil` when `date` is not in quiet hours.
    public func end(of date: Date, calendar: Calendar) -> Date? {
        guard contains(date, calendar: calendar),
              let end = calendar.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: date)
        else { return nil }
        return end > date ? end : calendar.date(byAdding: .day, value: 1, to: end)
    }
}

/// Reads and writes `settings.json`.
public final class SettingsStore {
    private let paths: JarvisPaths

    public init(paths: JarvisPaths) {
        self.paths = paths
    }

    /// Missing file → defaults. A file that exists but cannot be read or decoded → moved to
    /// `settings.json.bak`, defaults (never crash at launch).
    public func load() -> Settings {
        let fm = FileManager.default
        let file = paths.settingsFile
        guard fm.fileExists(atPath: file.path) else { return .default }
        if let data = try? Data(contentsOf: file),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) { return settings }
        let bak = file.appendingPathExtension("bak")
        // Replace, not remove-then-move: a failed move must not cost the previous backup.
        if fm.fileExists(atPath: bak.path) {
            _ = try? fm.replaceItemAt(bak, withItemAt: file)
        } else {
            try? fm.moveItem(at: file, to: bak)
        }
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
