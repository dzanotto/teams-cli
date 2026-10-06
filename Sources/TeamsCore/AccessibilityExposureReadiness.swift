import Foundation

/// Confirms an accessibility attribute without an unconditional settling delay.
/// Generation checks bracket each read so a replacement Teams process cannot
/// satisfy readiness for the process whose attribute we changed.
struct AccessibilityExposureReadiness {
    enum Result: Equatable {
        case confirmed
        case processGone
        case unavailable
        case timedOut
    }

    let sameGeneration: () -> Bool?
    /// The argument caps the AX message timeout to the remaining polling budget.
    let read: (TimeInterval) -> Bool?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wait: (TimeInterval) -> Void = {
        RunLoop.current.run(until: Date().addingTimeInterval($0))
    }

    func waitFor(_ expected: Bool) -> Result {
        let deadline = now() + 0.4
        while true {
            guard let sameBefore = sameGeneration() else { return .unavailable }
            guard sameBefore else { return .processGone }
            let remaining = deadline - now()
            guard remaining > 0 else { return .timedOut }

            let value = read(min(0.25, remaining))
            guard let sameAfter = sameGeneration() else { return .unavailable }
            guard sameAfter else { return .processGone }
            guard now() <= deadline else { return .timedOut }
            if value == expected { return .confirmed }

            let waitBudget = deadline - now()
            guard waitBudget > 0 else { return .timedOut }
            wait(min(0.025, waitBudget))
        }
    }
}
