import Foundation
import os

/// Jarvis's log (J-012): `log stream --predicate 'subsystem == "dev.yashmangal.jarvis"'`.
/// Privacy: an error is logged by its kind in the clear and its description as private; sources, counts and
/// durations are public; paths are private. Never transcript or command text.
/// Interpolate an error's description as `String(describing: error)`: an `Error` interpolated directly is
/// printed in full even when marked `.private` (seen on macOS 27).
enum Log {
    static let subsystem = "dev.yashmangal.jarvis"
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let transcribe = Logger(subsystem: subsystem, category: "transcribe")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let imports = Logger(subsystem: subsystem, category: "import")
    static let notes = Logger(subsystem: subsystem, category: "notes")
}

extension Error {
    /// The error's domain and code, which every Swift error has as an `NSError`. Never its message: a
    /// transcriber's message could quote what it heard.
    var logKind: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}
