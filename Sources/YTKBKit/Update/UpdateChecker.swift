import Foundation

/// Snapshot of an available update.
package struct AppUpdate: Equatable, Sendable {
    package let version: String           // "1.6.0" (no "v" prefix)
    package let tag: String               // "v1.6.0" — used for download asset URL
    package let assetURL: URL             // DMG download URL (may need auth header)
    package let assetId: Int              // GitHub asset id (for private-repo authenticated download)
    package let assetName: String         // "YTKB.dmg"
    package let releaseURL: URL           // human-readable release page
    package let releaseNotes: String      // body of the GitHub release
}

/// Polls GitHub Releases for newer versions and reports back on the main actor.
actor UpdateChecker {
    static let shared = UpdateChecker()

    /// Owner/repo of the GitHub repository hosting the releases.
    private let owner = "leopavlinskiy"
    private let repo = "yt-kb-app"

    private init() {}

    /// Fetch the latest release; return AppUpdate if it's strictly newer than
    /// the running CFBundleShortVersionString. Returns nil otherwise.
    /// `token` is a GitHub Personal Access Token (PAT) — required for private
    /// repos. Public repos work without a token (with API rate limits).
    package func checkLatest(token: String?) async throws -> AppUpdate? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("yt-kb-app/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("Не HTTP ответ")
        }
        if http.statusCode == 404 {
            throw UpdateError.network("404 — репозиторий приватный? Нужен GitHub-токен в Settings.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UpdateError.network("\(http.statusCode) — токен невалиден или нет прав на repo.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.network("HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.parse("malformed JSON")
        }
        guard let tag = json["tag_name"] as? String else {
            throw UpdateError.parse("no tag_name")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        // Strictly newer than the running version?
        if !Self.semverGreater(version, than: currentVersion) {
            Logger.shared.info("UpdateChecker: latest=\(version), current=\(currentVersion) — already up to date")
            return nil
        }

        // Find the .dmg asset
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") ?? false }),
              let assetId = dmg["id"] as? Int,
              let assetName = dmg["name"] as? String,
              let downloadURLString = dmg["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            throw UpdateError.parse("no DMG asset in release")
        }
        let releaseURLString = (json["html_url"] as? String) ?? "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)"
        let releaseURL = URL(string: releaseURLString) ?? downloadURL
        let releaseNotes = (json["body"] as? String) ?? ""

        Logger.shared.info("UpdateChecker: update available \(currentVersion) → \(version)")
        return AppUpdate(
            version: version,
            tag: tag,
            assetURL: downloadURL,
            assetId: assetId,
            assetName: assetName,
            releaseURL: releaseURL,
            releaseNotes: releaseNotes
        )
    }

    /// Builds the authenticated asset download URL. For private repos
    /// browser_download_url returns 404 anonymously; the API endpoint
    /// `/releases/assets/<id>` with `Accept: octet-stream` redirects to a
    /// time-limited signed URL.
    package func authenticatedAssetURLRequest(for update: AppUpdate, token: String?) -> URLRequest {
        if let token = token, !token.isEmpty {
            let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/assets/\(update.assetId)")!
            var req = URLRequest(url: api)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("yt-kb-app/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            return req
        } else {
            return URLRequest(url: update.assetURL)
        }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Naive semver comparison: split by "." and compare integers component
    /// by component. Pre-release suffixes (e.g. "1.6.0-beta") are stripped
    /// before parsing. Returns true if `a > b`.
    package static func semverGreater(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let ai = i < pa.count ? pa[i] : 0
            let bi = i < pb.count ? pb[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }
}

package enum UpdateError: Error, CustomStringConvertible {
    case network(String)
    case parse(String)
    case install(String)

    package var description: String {
        switch self {
        case .network(let m): return "сеть: \(m)"
        case .parse(let m): return "parse: \(m)"
        case .install(let m): return "install: \(m)"
        }
    }
}
