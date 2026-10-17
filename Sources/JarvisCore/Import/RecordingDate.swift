import AVFoundation
import CoreServices
import Foundation

/// When a recording was made, from the file's own metadata.
public enum RecordingDate {
    /// The asset's creation-date metadata, then Spotlight's content creation date, then the
    /// file's creation date, then now. Spotlight may not have indexed a freshly dropped file yet,
    /// and a file copied with `cp`, downloaded or similar gets a creation date equal to the copy
    /// time, so a recording with no date metadata of its own is dated by when it was copied in.
    public static func of(_ url: URL) async -> Date {
        if let item = try? await AVURLAsset(url: url).load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        if let item = MDItemCreate(nil, url.path as CFString),
           let date = MDItemCopyAttribute(item, kMDItemContentCreationDate) as? Date {
            return date
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }
}
