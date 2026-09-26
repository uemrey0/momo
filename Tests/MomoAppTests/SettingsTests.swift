import Foundation
import Testing

@testable import MomoApp

@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test("the sidebar shows every pane once, in the panes' order")
    func sidebarSections() {
        let panes = SettingsSidebarSection.allCases.flatMap(\.panes)
        #expect(panes == SettingsPane.allCases)
    }
}
