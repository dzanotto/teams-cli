import ApplicationServices
import XCTest
@testable import TeamsCore

/// Local identity tokens and scripted results only; no native attribute calls occur.
final class AccessibilityAttributeStub {
    let application = AXUIElementCreateApplication(123)
    var value: CFTypeRef? = kCFBooleanFalse
    var readError = AXError.success
    var writeError = AXError.success
    var applyWrites = true
    var onRead: (() -> Void)?
    var events: [String] = []
    private(set) var timeouts: [Float] = []
    private(set) var writes: [(String, CFTypeRef)] = []

    var client: AccessibilityAttributeClient {
        AccessibilityAttributeClient(makeApplication: { pid in
            self.events.append("application \(pid)")
            return self.application
        }, setMessagingTimeout: { element, timeout in
            XCTAssertTrue(CFEqual(element, self.application))
            self.events.append("timeout")
            self.timeouts.append(timeout)
        }, copyAttribute: { element, name in
            XCTAssertTrue(CFEqual(element, self.application))
            self.events.append("read \(name)")
            self.onRead?()
            return (self.value, self.readError)
        }, setAttribute: { element, name, value in
            XCTAssertTrue(CFEqual(element, self.application))
            self.events.append("write \(name)")
            self.writes.append((name, value))
            if self.applyWrites { self.value = value }
            return self.writeError
        })
    }
}
