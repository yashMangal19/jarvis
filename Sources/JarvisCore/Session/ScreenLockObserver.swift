import Foundation

/// Tells the listening session when the screen locks and unlocks.
public protocol ScreenLockObserving: AnyObject {
    var onLock: (() -> Void)? { get set }
    var onUnlock: (() -> Void)? { get set }
}

/// Listens for the system's screen lock broadcasts. Thin wrapper, not unit-tested: posting the real
/// notifications from a test would be seen by every process on the Mac.
public final class DistributedScreenLockObserver: ScreenLockObserving {
    public var onLock: (() -> Void)?
    public var onUnlock: (() -> Void)?

    private let center = DistributedNotificationCenter.default()
    private var tokens: [NSObjectProtocol] = []

    public init() {
        tokens = [
            center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                self?.onLock?()
            },
            center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                self?.onUnlock?()
            },
        ]
    }

    deinit { tokens.forEach(center.removeObserver) }
}
