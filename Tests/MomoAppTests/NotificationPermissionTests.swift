import Testing
import UserNotifications

@testable import MomoApp

@Suite("Notification permission")
struct NotificationPermissionTests {
    @Test("posts when the user allowed notifications, even provisionally")
    func allowed() {
        #expect(ContextMonitor.mayNotify(.authorized))
        #expect(ContextMonitor.mayNotify(.provisional))
    }

    @Test("stays quiet until the user allows notifications")
    func notAllowed() {
        #expect(!ContextMonitor.mayNotify(.notDetermined))
        #expect(!ContextMonitor.mayNotify(.denied))
    }
}
