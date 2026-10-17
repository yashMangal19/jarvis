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
    /// Most likely first. The group container is the documented layout since macOS 12; its
    /// `Recordings/` folder only appears once a memo has synced, and on the dev Mac none has yet, so
    /// this path is unverified until one does. The Application Support folder is the documented layout
    /// of macOS 10.14–11, kept for Macs still carrying it.
    public static let candidates: [URL] = {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return [
            library.appending(path: "Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
            library.appending(path: "Application Support/com.apple.voicememos/Recordings"),
        ]
    }()

    /// The first candidate that can be listed is `.readable`; the first whose listing is refused for
    /// lack of permission (EPERM, EACCES) is `.unreadable`; a candidate that is missing or not a folder
    /// is skipped. The listing's own error decides: TCC can refuse even the existence check of a
    /// folder inside a protected container, so checking existence first would read a refusal as absent.
    /// Only ever lists; never opens a recording. `list` is the file-system seam for tests.
    public static func probe(_ candidates: [URL] = candidates,
                             list: (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) })
        -> VoiceMemosAccess {
        for folder in candidates {
            do {
                _ = try list(folder)
                return .readable(folder)
            } catch where isRefusal(error) {
                return .unreadable(folder)
            } catch {
                continue
            }
        }
        return .absent
    }

    /// Permission refused, as FileManager reports it (Cocoa 257 over POSIX EPERM/EACCES) or as a bare POSIX error.
    private static func isRefusal(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return false }
        return posix.code == Int(EPERM) || posix.code == Int(EACCES)
    }
}
