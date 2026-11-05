import AppKit

struct AccessibilityExposureProcess {
    let pid: pid_t
    let isTerminated: Bool
    let launchDate: Date?
}

/// Process snapshots and attribute calls keep the system adapter independent of a live desktop in tests.
struct AccessibilityExposureEnvironment {
    let runningApplications: (String) -> [AccessibilityExposureProcess]
    let runningApplication: (pid_t) -> AccessibilityExposureProcess?
    let attributes: AccessibilityAttributeClient
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wait: (TimeInterval) -> Void = { RunLoop.current.run(until: Date().addingTimeInterval($0)) }

    static var live: Self {
        Self(runningApplications: { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(snapshot)
        }, runningApplication: { pid in
            NSRunningApplication(processIdentifier: pid).map(snapshot)
        }, attributes: .live)
    }

    private static func snapshot(_ application: NSRunningApplication) -> AccessibilityExposureProcess {
        AccessibilityExposureProcess(pid: application.processIdentifier, isTerminated: application.isTerminated,
                                     launchDate: application.launchDate)
    }
}
