import Foundation
import MomoKit
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

    @Test("every searchable setting is in a pane of the sidebar")
    func searchPanesExist() {
        let panes = Set(SettingsSidebarSection.allCases.flatMap(\.panes))
        for setting in SettingsSearch.all {
            #expect(panes.contains(setting.pane), "\(setting.title) is in a hidden pane")
        }
    }

    @Test("searchable titles are unique within their pane")
    func uniqueTitles() {
        for pane in SettingsPane.allCases {
            let titles = SettingsSearch.all.filter { $0.pane == pane }.map(\.title)
            #expect(Set(titles).count == titles.count, "Duplicate titles in \(pane)")
        }
    }

    @Test("anchors are unique across Settings")
    func uniqueAnchors() {
        let anchors = SettingsSearch.all.compactMap(\.anchor)
        #expect(Set(anchors).count == anchors.count)
    }

    @Test("every pane has searchable settings")
    func everyPaneIsSearchable() {
        let searchable = Set(SettingsSearch.all.map(\.pane))
        #expect(searchable == Set(SettingsPane.allCases))
    }

    @Test("search finds single settings by title and keyword")
    func findsSettings() {
        #expect(SettingsSearch.results(for: "login").contains { $0.anchor == "general.login" })
        #expect(
            SettingsSearch.results(for: "wake word").contains { $0.pane == .voice })
        #expect(
            SettingsSearch.results(for: "contacts").contains {
                $0.anchor == MacPermission.contacts.anchor
            })
        #expect(SettingsSearch.results(for: "   ").isEmpty)
    }
}
