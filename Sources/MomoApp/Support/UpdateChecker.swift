import AppKit
import Foundation
import MomoKit
import Observation

/// Checks GitHub Releases once a day for a newer version of Momo.
///
/// Stable builds only hear about stable releases. Pre-release builds (`0.2.0-beta.2`) also hear
/// about newer pre-releases.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Equatable {
        var version: String
        var url: URL
    }

    /// A release as GitHub lists it.
    struct PublishedRelease: Equatable {
        var tag: String
        var url: URL
        var isDraft = false
        var isPrerelease = false
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable
        case failed(String)
    }

    /// Fetches a request, like `URLSession.data(for:)`.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private(set) var availableUpdate: Release?
    private(set) var status = Status.idle
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    private static let latestEndpoint = URL(
        literal: "https://api.github.com/repos/uemrey0/momo/releases/latest")
    private static let listEndpoint = URL(
        literal: "https://api.github.com/repos/uemrey0/momo/releases?per_page=10")
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 3600

    init(
        settings: AppSettings,
        defaults: UserDefaults = .standard,
        currentVersion: String = UpdateChecker.bundleVersion,
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }
    ) {
        self.settings = settings
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Checks now if due, then again every hour and after the Mac wakes, so a check that
    /// failed (say, before Wi-Fi was up) is retried while Momo keeps running.
    func start() {
        checkIfDue()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.checkIfDue()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    /// Checks when automatic checks are on and the last successful check is more than a day old.
    func checkIfDue() {
        guard settings.preferences.checksForUpdates, status != .checking else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        Task { await check() }
    }

    func check() async {
        guard status != .checking else { return }
        status = .checking
        let current = SemanticVersion(currentVersion)
        let includesPrereleases = current?.prerelease != nil
        var request = URLRequest(url: includesPrereleases ? Self.listEndpoint : Self.latestEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let data: Data
        do {
            let (body, response) = try await fetch(request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status = .failed(String(format: L("GitHub answered with error %d."), code))
                return
            }
            data = body
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        guard let releases = Self.parseReleases(data), let current else {
            status = .failed(L("GitHub's answer couldn't be read."))
            return
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        availableUpdate = Self.update(for: current, among: releases)
        status = availableUpdate == nil ? .upToDate : .updateAvailable
    }

    /// The newest release worth offering to someone running `current`, or `nil` when they are
    /// up to date. Drafts are skipped, and pre-releases are offered only to pre-release builds.
    nonisolated static func update(
        for current: SemanticVersion, among releases: [PublishedRelease]
    ) -> Release? {
        let includesPrereleases = current.prerelease != nil
        let candidates = releases.compactMap { release -> (SemanticVersion, URL)? in
            guard !release.isDraft, let version = SemanticVersion(release.tag) else { return nil }
            let isPrerelease = release.isPrerelease || version.prerelease != nil
            guard includesPrereleases || !isPrerelease else { return nil }
            return (version, release.url)
        }
        guard let (newest, url) = candidates.max(by: { $0.0 < $1.0 }), newest > current else {
            return nil
        }
        return Release(version: newest.description, url: url)
    }

    /// Reads a single release (`/releases/latest`) or a list of them (`/releases`).
    nonisolated static func parseReleases(_ data: Data) -> [PublishedRelease]? {
        guard let json = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            return nil
        }
        let items = json.arrayValue ?? [json]
        let releases = items.compactMap { item -> PublishedRelease? in
            guard let tag = item["tag_name"]?.stringValue,
                let url = item["html_url"]?.stringValue.flatMap(URL.init(string:))
            else { return nil }
            return PublishedRelease(
                tag: tag, url: url, isDraft: item["draft"]?.boolValue ?? false,
                isPrerelease: item["prerelease"]?.boolValue ?? false)
        }
        return releases.isEmpty && json.arrayValue == nil ? nil : releases
    }

    func openReleasePage() {
        if let url = availableUpdate?.url { NSWorkspace.shared.open(url) }
    }
}
