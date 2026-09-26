import AppKit
import Foundation
import MomoKit
import Observation

/// Checks GitHub Releases once a day for a newer version of Momo.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        var version: String
        var url: URL
    }

    private(set) var availableUpdate: Release?
    @ObservationIgnored private let settings: AppSettings
    private static let endpoint = URL(
        literal: "https://api.github.com/repos/uemrey0/momo/releases/latest")
    private static let lastCheckKey = "lastUpdateCheck"

    init(settings: AppSettings) {
        self.settings = settings
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Checks when automatic checks are on and the last check is more than a day old.
    func checkIfDue() {
        guard settings.preferences.checksForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check() }
    }

    func check() async {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONValue.parse(String(decoding: data, as: UTF8.self)),
            let tag = json["tag_name"]?.stringValue,
            let page = json["html_url"]?.stringValue.flatMap(URL.init(string:)),
            let latest = SemanticVersion(tag),
            let current = SemanticVersion(Self.currentVersion)
        else { return }
        availableUpdate = latest > current ? Release(version: latest.description, url: page) : nil
    }

    func openReleasePage() {
        if let url = availableUpdate?.url { NSWorkspace.shared.open(url) }
    }
}
