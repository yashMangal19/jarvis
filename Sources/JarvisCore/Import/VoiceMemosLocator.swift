import Foundation

/// Whether the Voice Memos recordings folder can be read.
public enum VoiceMemosAccess: Equatable {
    case readable(URL)
    /// The folder exists but listing it is refused: Jarvis needs Full Disk Access.
    case unreadable(URL)
    /// No candidate folder exists (Voice Memos has never synced a recording to this Mac).
    case absent
}

/// Finds the folder where Voice Memos keeps the recordings it syncs from iCloud.
public enum VoiceMemosLocator {
    /// Most likely first. The group container is the layout since macOS 12 and exists on macOS 27;
    /// its `Recordings/` folder only appears once a memo has synced. The Application Support folder
    /// is the layout of macOS 10.14–11, kept for Macs still carrying it.
    public static let candidates: [URL] = {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return [
            library.appending(path: "Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
            library.appending(path: "Application Support/com.apple.voicememos/Recordings"),
        ]
    }()

    /// The first candidate that exists as a folder: `.readable` if it can be listed, `.unreadable` if
    /// listing it is refused for lack of permission. Only ever lists; never opens a recording.
    public static func probe(_ candidates: [URL] = candidates) -> VoiceMemosAccess {
        for folder in candidates {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue
            else { continue }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                return .readable(folder)
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                return .unreadable(folder)
            } catch {
                continue
            }
        }
        return .absent
    }
}
