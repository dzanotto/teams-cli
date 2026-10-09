import Foundation

/// Keeps command lifecycle, native reads, and polling injectable as one unit.
struct MediaActionEnvironment<Focus: MediaCommandFocus> {
    let lifecycle: MediaCommandEnvironment<Focus>
    let makeAccessibility: () -> any MediaAccessibilityClient
    let wait: (TimeInterval) -> Void

    // Hand and call-end retain their existing cadence and sample limits.
    var waitForUpdate: () -> Void { { wait(0.15) } }
}

extension MediaActionEnvironment where Focus == FocusMonitor {
    static var live: Self { recordingTimings(nil) }

    static func recordingTimings(_ timings: CommandTimings?) -> Self {
        Self(lifecycle: .live, makeAccessibility: { SystemMediaAccessibilityClient(timings: timings) }, wait: {
            RunLoop.current.run(until: Date().addingTimeInterval($0))
        })
    }
}
