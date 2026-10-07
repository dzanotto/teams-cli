import Foundation

/// Keeps command lifecycle, native reads, and polling injectable as one unit.
struct MediaActionEnvironment<Focus: MediaCommandFocus> {
    let lifecycle: MediaCommandEnvironment<Focus>
    let makeAccessibility: () -> any MediaAccessibilityClient
    let waitForUpdate: () -> Void
}

extension MediaActionEnvironment where Focus == FocusMonitor {
    static var live: Self {
        Self(lifecycle: .live, makeAccessibility: { SystemMediaAccessibilityClient() }, waitForUpdate: {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        })
    }
}
