import CryptoKit
import Foundation

/// The whisper models Jarvis may download, pinned to one revision of huggingface.co/ggerganov/whisper.cpp with
/// each file's sha256 (J-026, DEC-53). The same values are in `install/whisper-models.txt`, which the installer
/// and release-formula.sh read; a test checks that the two agree.
public enum WhisperModels {
    public struct Pins: Equatable, Sendable {
        public let revision: String
        /// File name → sha256, lowercase hex.
        public let files: [String: String]

        public init(revision: String, files: [String: String]) {
            self.revision = revision
            self.files = files
        }

        /// The download address at the pinned revision; never a moving branch.
        public func url(for file: String) -> URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)/\(file)")!
        }
    }

    public static let pinned = Pins(revision: "5359861c739e955e79d9a303bcbc70fb988958b1", files: [
        "ggml-base.en.bin": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        "ggml-small.bin": "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        "ggml-medium.bin": "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        "ggml-large-v3-turbo.bin": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    ])

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The file's sha256, read in 1 MB pieces so a 1.6 GB model never sits in memory whole.
    static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hasher.update(data: piece) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
