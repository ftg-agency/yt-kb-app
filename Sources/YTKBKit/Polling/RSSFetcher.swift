import Foundation

package struct RSSVideo: Sendable, Equatable {
    package let videoId: String
    package let title: String?
    package let published: Date?
}

package enum RSSFetchError: Error, CustomStringConvertible {
    case missingChannelId
    case http(Int)
    case network(String)
    case parse(String)
    case empty

    package var description: String {
        switch self {
        case .missingChannelId: return "RSS: нет channel_id"
        case .http(let code):   return "RSS HTTP \(code)"
        case .network(let m):   return "RSS сеть: \(m)"
        case .parse(let m):     return "RSS парсинг: \(m)"
        case .empty:            return "RSS: пустой ответ"
        }
    }
}

/// Lightweight Atom-feed fetcher for YouTube channels. Returns the ~15 most
/// recent videos via a single HTTP GET (~5-20KB body, ~200ms). Drastically
/// cheaper than going through yt-dlp for "is there anything new" checks.
///
/// Endpoint: https://www.youtube.com/feeds/videos.xml?channel_id=UC...
/// No auth, no cookies, no rate-limit headers documented but stable for tens
/// of thousands of requests/day from a single IP in practice.
package actor RSSFetcher {
    package static let shared = RSSFetcher()

    private let session: URLSession

    package init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        c.urlCache = nil
        self.session = URLSession(configuration: c)
    }

    package func fetchLatest(channelId: String) async throws -> [RSSVideo] {
        guard channelId.hasPrefix("UC") else { throw RSSFetchError.missingChannelId }
        let urlString = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)"
        guard let url = URL(string: urlString) else {
            throw RSSFetchError.parse("кривой URL: \(urlString)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw RSSFetchError.network("\(error)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RSSFetchError.http(http.statusCode)
        }
        let parser = YTRSSParser()
        let videos = try parser.parse(data: data)
        if videos.isEmpty { throw RSSFetchError.empty }
        return videos
    }
}

/// Minimal XMLParser delegate that pulls <entry> blocks out of YouTube's Atom
/// feed. We only care about `yt:videoId`, `title`, `published`. Anything else
/// is ignored. Safe to instantiate per-fetch — keeps no shared state.
package final class YTRSSParser: NSObject, XMLParserDelegate {
    private var videos: [RSSVideo] = []
    private var inEntry = false
    private var currentId: String?
    private var currentTitle: String?
    private var currentPublished: String?
    private var buffer = ""
    private var parseError: Error?

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    package func parse(data: Data) throws -> [RSSVideo] {
        let p = XMLParser(data: data)
        p.delegate = self
        guard p.parse() else {
            let msg = p.parserError.map { "\($0)" } ?? "неизвестная ошибка XML"
            throw RSSFetchError.parse(msg)
        }
        if let e = parseError { throw e }
        return videos
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        buffer = ""
        if elementName == "entry" {
            inEntry = true
            currentId = nil
            currentTitle = nil
            currentPublished = nil
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inEntry else { buffer = ""; return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "yt:videoId":
            currentId = value
        case "title":
            currentTitle = value
        case "published":
            currentPublished = value
        case "entry":
            if let id = currentId, id.count == 11 {
                let date = currentPublished.flatMap { Self.parseDate($0) }
                videos.append(RSSVideo(videoId: id, title: currentTitle, published: date))
            }
            inEntry = false
        default:
            break
        }
        buffer = ""
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let d = dateFormatter.date(from: raw) { return d }
        // Fallback without fractional seconds — YouTube does not include them.
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }
}
