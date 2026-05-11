import Foundation

/// Ultra-light channel metadata fetch via plain HTTP — bypasses yt-dlp's
/// 10+ second Python startup + InnerTube discovery dance. We just GET the
/// channel page HTML and extract `og:title` and `channelId` from meta tags.
///
/// Typical wallclock: ~500ms. Falls through to yt-dlp's quickResolve on
/// any failure (geo-block, restricted channel, parse error).
package actor ChannelPageFetcher {
    package static let shared = ChannelPageFetcher()

    private let session: URLSession

    package init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        c.urlCache = nil
        self.session = URLSession(configuration: c)
    }

    package struct Result: Sendable {
        package let name: String
        package let channelId: String?
        package let canonicalURL: String
    }

    package enum FetchError: Error, CustomStringConvertible {
        case badURL
        case http(Int)
        case network(String)
        case parse(String)

        package var description: String {
            switch self {
            case .badURL:        return "ChannelPageFetcher: bad URL"
            case .http(let c):   return "ChannelPageFetcher: HTTP \(c)"
            case .network(let m): return "ChannelPageFetcher: network: \(m)"
            case .parse(let m):   return "ChannelPageFetcher: parse: \(m)"
            }
        }
    }

    package func fetchMetadata(channelURL: String) async throws -> Result {
        let t0 = Date()
        guard let url = URL(string: channelURL) else { throw FetchError.badURL }
        Logger.shared.info("channelPage ▶ \(channelURL)")

        var request = URLRequest(url: url)
        // Mobile-ish UA gives a smaller, cleaner HTML (server-rendered meta
        // tags are still there). Avoids YouTube's heavy JS-only desktop page.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("ru,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Logger.shared.warn("channelPage ◀ network FAIL in \(msSince(t0)): \(error)")
            throw FetchError.network("\(error)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            Logger.shared.warn("channelPage ◀ HTTP \(http.statusCode) in \(msSince(t0))")
            throw FetchError.http(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw FetchError.parse("HTML не UTF-8")
        }

        guard let name = extractName(from: html) else {
            Logger.shared.warn("channelPage ◀ no og:title in \(msSince(t0)) (body=\(data.count)B)")
            throw FetchError.parse("og:title не найден")
        }
        let channelId = extractChannelId(from: html)
        let canonical = extractCanonicalURL(from: html) ?? channelURL

        Logger.shared.info("channelPage ◀ ok in \(msSince(t0)): \(name) (\(channelId ?? "no-id"))")
        return Result(name: name, channelId: channelId, canonicalURL: canonical)
    }

    private nonisolated func msSince(_ date: Date) -> String {
        "\(Int(Date().timeIntervalSince(date) * 1000))ms"
    }

    /// `<meta property="og:title" content="Channel Name - YouTube">`
    /// or `<title>Channel Name - YouTube</title>`. Strips " - YouTube" suffix.
    private nonisolated func extractName(from html: String) -> String? {
        if let raw = firstMatch(in: html, pattern: #"<meta\s+property="og:title"\s+content="([^"]+)""#) {
            return cleanName(raw)
        }
        if let raw = firstMatch(in: html, pattern: #"<title>([^<]+)</title>"#) {
            return cleanName(raw)
        }
        return nil
    }

    private nonisolated func cleanName(_ raw: String) -> String? {
        let trimmed = raw
            .replacingOccurrences(of: " - YouTube", with: "")
            .replacingOccurrences(of: " — YouTube", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Looks for UCxxxx in:
    ///   <meta itemprop="channelId" content="UCxxxx">
    ///   <link rel="canonical" href="https://www.youtube.com/channel/UCxxxx">
    ///   "channelId":"UCxxxx" in ytInitialData JS blob
    private nonisolated func extractChannelId(from html: String) -> String? {
        if let id = firstMatch(in: html, pattern: #"<meta\s+itemprop="channelId"\s+content="(UC[A-Za-z0-9_-]{22})""#) {
            return id
        }
        if let id = firstMatch(in: html, pattern: #"<link\s+rel="canonical"\s+href="https://www\.youtube\.com/channel/(UC[A-Za-z0-9_-]{22})"#) {
            return id
        }
        if let id = firstMatch(in: html, pattern: #""channelId":"(UC[A-Za-z0-9_-]{22})""#) {
            return id
        }
        if let id = firstMatch(in: html, pattern: #""externalId":"(UC[A-Za-z0-9_-]{22})""#) {
            return id
        }
        return nil
    }

    private nonisolated func extractCanonicalURL(from html: String) -> String? {
        firstMatch(in: html, pattern: #"<link\s+rel="canonical"\s+href="([^"]+)""#)
    }

    private nonisolated func firstMatch(in haystack: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let match = regex.firstMatch(in: haystack, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: haystack) else { return nil }
        return String(haystack[r])
    }
}
