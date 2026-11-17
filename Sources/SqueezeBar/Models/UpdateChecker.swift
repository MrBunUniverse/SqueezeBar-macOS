import Foundation
import Combine

struct ReleaseVersion: Comparable {
    let parts: [Int]
    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = pieces.map { Int($0)! }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool

    var trustedURL: URL? {
        guard html_url.scheme == "https", html_url.host == "github.com",
              html_url.user == nil, html_url.password == nil, html_url.port == nil,
              html_url.path.hasPrefix("/MrBunUniverse/SqueezeBar-macOS/releases/tag/"),
              html_url.pathComponents.count == 6 else { return nil }
        return html_url
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    nonisolated static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }
    @Published var automatic: Bool { didSet {
        defaults.set(automatic, forKey: "automaticUpdateChecks")
        if automatic { Task { await check(manual: false) } }
    } }
    @Published private(set) var checking = false
    @Published private(set) var release: GitHubRelease?
    @Published private(set) var feedback: String?
    @Published private var dismissedVersion: String?
    var bannerRelease: GitHubRelease? { release?.tag_name == dismissedVersion ? nil : release }
    private let defaults: UserDefaults
    private let version: String
    private let now: () -> Date
    private let transport: (URLRequest) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard, version: String = UpdateChecker.appVersion,
         now: @escaping () -> Date = Date.init,
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.version = version
        self.now = now
        self.transport = transport
        automatic = defaults.bool(forKey: "automaticUpdateChecks")
    }

    func dismiss() { dismissedVersion = release?.tag_name }

    func check(manual: Bool) async {
        guard !checking else { return }
        if !manual {
            guard automatic else { return }
            if let last = defaults.object(forKey: "lastUpdateCheck") as? Date,
               now().timeIntervalSince(last) < 86400 { return }
        }
        checking = true
        defaults.set(now(), forKey: "lastUpdateCheck")
        if manual { feedback = nil }
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/MrBunUniverse/SqueezeBar-macOS/releases/latest")!)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let candidate = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let current = ReleaseVersion(version), let latest = ReleaseVersion(candidate.tag_name),
                  candidate.trustedURL != nil else { throw URLError(.cannotParseResponse) }
            release = !candidate.draft && !candidate.prerelease && latest > current ? candidate : nil
            if manual {
                dismissedVersion = nil
                feedback = release == nil ? String(localized: "You’re up to date.") : String(localized: "An update is available.")
            }
        } catch {
            if manual { feedback = String(localized: "Couldn’t check for updates. Please try again later.") }
        }
    }

    nonisolated static func bugReportURL(version: String = appVersion, system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> URL {
        var components = URLComponents(string: "https://github.com/MrBunUniverse/SqueezeBar-macOS/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: "App version: \(version)\nmacOS: \(system)\n\nWhat happened\n\nSteps to reproduce\n\nExpected behavior\n")]
        return components.url!
    }
}
