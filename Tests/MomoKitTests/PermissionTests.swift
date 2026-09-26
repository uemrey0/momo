import Foundation
import Testing

@testable import MomoKit

@Suite("Permissions")
struct PermissionTests {
    @Test(
        "identifiers survive a round trip",
        arguments: [
            MacPermission.microphone, .speechRecognition, .calendars, .reminders, .contacts,
            .screenRecording, .accessibility, .automation(nil), .automation("com.apple.Music"),
            .notifications, .location,
        ])
    func roundTrip(permission: MacPermission) {
        #expect(MacPermission(id: permission.id) == permission)
    }

    @Test("rejects unknown identifiers")
    func rejectsUnknown() {
        #expect(MacPermission(id: "camera") == nil)
        #expect(MacPermission(id: "automation:") == nil)
    }

    @Test("tells the model what is missing and where to allow it")
    func describesTheFix() {
        let error = PermissionRequired(.contacts, "Momo can't read Contacts.")
        let text = error.localizedDescription
        #expect(text.hasPrefix("Momo can't read Contacts."))
        #expect(text.contains("Momo Settings → Permissions"))
    }
}
