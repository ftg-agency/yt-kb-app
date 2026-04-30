import Foundation

struct SubFormat: Decodable {
    let ext: String?
    let url: String?
}

struct VideoMetadata: Decodable {
    let id: String
    let title: String?
    let channel: String?
    let uploader: String?
    let channelId: String?
    let uploaderId: String?
    let channelUrl: String?
    let uploaderUrl: String?
    let language: String?
    let originalLanguage: String?
    let uploadDate: String?
    let duration: Double?
    let viewCount: Int?
    let webpageUrl: String?
    let description: String?
    let subtitles: [String: [SubFormat]]?
    let automaticCaptions: [String: [SubFormat]]?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, language, duration, description, subtitles
        case channelId = "channel_id"
        case uploaderId = "uploader_id"
        case channelUrl = "channel_url"
        case uploaderUrl = "uploader_url"
        case originalLanguage = "original_language"
        case uploadDate = "upload_date"
        case viewCount = "view_count"
        case webpageUrl = "webpage_url"
        case automaticCaptions = "automatic_captions"
    }

    var hasAnySubs: Bool {
        !(subtitles?.isEmpty ?? true) || !(automaticCaptions?.isEmpty ?? true)
    }

    var displayChannel: String { channel ?? uploader ?? "Unknown" }
    var displayChannelURL: String { channelUrl ?? uploaderUrl ?? "" }
    var displayChannelId: String? { channelId ?? uploaderId }
    var canonicalURL: String { webpageUrl ?? "https://www.youtube.com/watch?v=\(id)" }
}

struct FlatPlaylistEntry: Decodable {
    let id: String?
    let title: String?
    let url: String?
    let webpageUrl: String?
    let _type: String?
    let entries: [FlatPlaylistEntry]?

    enum CodingKeys: String, CodingKey {
        case id, title, url, entries
        case webpageUrl = "webpage_url"
        case _type = "_type"
    }
}

struct FlatPlaylistResponse: Decodable {
    let id: String?
    let title: String?
    let channel: String?
    let uploader: String?
    let channelId: String?
    let uploaderId: String?
    let channelUrl: String?
    let entries: [FlatPlaylistEntry]?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, entries
        case channelId = "channel_id"
        case uploaderId = "uploader_id"
        case channelUrl = "channel_url"
    }

    var displayName: String { channel ?? uploader ?? title ?? "Unknown" }
}

struct VideoRef: Equatable, Identifiable {
    var id: String { videoId }
    let videoId: String
    let title: String?
    var url: String { "https://www.youtube.com/watch?v=\(videoId)" }
}
