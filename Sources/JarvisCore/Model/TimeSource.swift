import Foundation

/// Time source, so tests can pin "now".
public protocol TimeSource {
    var now: Date { get }
}

/// The wall clock.
public struct SystemClock: TimeSource {
    public init() {}
    public var now: Date { Date() }
}
