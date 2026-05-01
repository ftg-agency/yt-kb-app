import Foundation

package struct SubFormat: Decodable {
    package let ext: String?
    package let url: String?
}

package struct VideoMetadata: Decodable {
    package let id: String
    package let title: String?
    package let channel: String?
    package let uploader: String?
    package let channelId: String?
    package let uploaderId: String?
    package let channelUrl: String?
    package let uploaderUrl: String?
    package let language: String?
    package let originalLanguage: String?
    package let uploadDate: String?
    package let duration: Double?
    package let viewCount: Int?
    package let webpageUrl: String?
    package let description: String?
    package let subtitles: [String: [SubFormat]]?
    package let automaticCaptions: [String: [SubFormat]]?

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

    package var hasAnySubs: Bool {
        !(subtitles?.isEmpty ?? true) || !(automaticCaptions?.isEmpty ?? true)
    }

    package var displayChannel: String { channel ?? uploader ?? "Unknown" }
    package var displayChannelURL: String { channelUrl ?? uploaderUrl ?? "" }
    package var displayChannelId: String? { channelId ?? uploaderId }
    package var canonicalURL: String { webpageUrl ?? "https://www.youtube.com/watch?v=\(id)" }
}

package struct FlatPlaylistEntry: Decodable {
    package let id: String?
    package let title: String?
    package let url: String?
    package let webpageUrl: String?
    package let _type: String?
    package let entries: [FlatPlaylistEntry]?

    enum CodingKeys: String, CodingKey {
        case id, title, url, entries
        case webpageUrl = "webpage_url"
        case _type = "_type"
    }
}

package struct FlatPlaylistResponse: Decodable {
    package let id: String?
    package let title: String?
    package let channel: String?
    package let uploader: String?
    package let channelId: String?
    package let uploaderId: String?
    package let channelUrl: String?
    package let entries: [FlatPlaylistEntry]?
    /// YouTube's reported total video count for the channel/playlist. May be
    /// larger than `entries.count` for big channels where yt-dlp's continuation
    /// loop hits the API cap. We surface the discrepancy in the UI.
    package let playlistCount: Int?
    package let channelFollowerCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, entries
        case channelId = "channel_id"
        case uploaderId = "uploader_id"
        case channelUrl = "channel_url"
        case playlistCount = "playlist_count"
        case channelFollowerCount = "channel_follower_count"
    }

    package var displayName: String { channel ?? uploader ?? title ?? "Unknown" }
}

package struct VideoRef: Equatable, Identifiable {
    package var id: String { videoId }
    package let videoId: String
    package let title: String?
    package var url: String { "https://www.youtube.com/watch?v=\(videoId)" }
}
