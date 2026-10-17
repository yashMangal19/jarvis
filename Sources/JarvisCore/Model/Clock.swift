import Foundation

/// Time source, so tests can pin "now".
public protocol Clock {
    var now: Date { get }
}

/// The wall clock.
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
