import Foundation

/// A tiny, dependency-free update check against the project's **GitHub Releases**. It compares the
/// running app's version to the latest published release tag and, if there's a newer one, hands back
/// the download link (preferring the `.dmg` asset, else the release page). No Sparkle, no keys, no
/// appcast — the "Check for Updates" button in Settings drives this. (Full silent auto-install would
/// be a later Sparkle upgrade.)
enum UpdateChecker {
    /// `owner/repo` of the PUBLIC GitHub repo that publishes releases.
    static let repo = "02-alt/emulator"

    enum Outcome {
        case upToDate
        case available(version: String, url: URL)
        case noReleases
        case failed(String)
    }

    /// The running app's version (`CFBundleShortVersionString`), or nil for an unbundled dev build.
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func check(current: String) async -> Outcome {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failed("Update URL is misconfigured.")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("No response from GitHub.") }
            if http.statusCode == 404 { return .noReleases }
            guard http.statusCode == 200 else { return .failed("GitHub returned \(http.statusCode).") }

            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard isNewer(latest, than: current) else { return .upToDate }

            let dmg = rel.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
            let link = URL(string: dmg ?? rel.html_url) ?? URL(string: rel.html_url)
            guard let link else { return .available(version: latest, url: URL(string: rel.html_url)!) }
            return .available(version: latest, url: link)
        } catch {
            return .failed("Couldn’t check for updates — are you online?")
        }
    }

    /// Numeric dotted-version compare so 1.10.0 sorts above 1.9.0 (component-wise, missing parts = 0).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]?
        struct Asset: Decodable { let browser_download_url: String; let name: String }
    }
}
