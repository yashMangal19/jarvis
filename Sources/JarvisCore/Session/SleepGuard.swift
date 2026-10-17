import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping. The session holds it exactly while listening.
public protocol SleepGuard {
    func hold()
    func release()
}

/// An IOKit "prevent user idle system sleep" assertion. Thin wrapper, not unit-tested (T-5 blueprint).
public final class IOKitSleepGuard: SleepGuard {
    private var assertionID: IOPMAssertionID?

    public init() {}

    deinit { release() }

    public func hold() {
        guard assertionID == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Jarvis is listening" as CFString,
            &id
        )
        if result == kIOReturnSuccess { assertionID = id }
    }

    public func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }
}
