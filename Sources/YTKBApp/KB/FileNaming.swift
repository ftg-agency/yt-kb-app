import Foundation

enum FileNaming {
    /// channel-slug-<6-char-id-suffix>
    static func channelDirName(meta: VideoMetadata) -> String {
        let name = meta.displayChannel.isEmpty ? "unknown-channel" : meta.displayChannel
        let baseSlug = Slugify.slug(name)
        if let cid = meta.displayChannelId, !cid.isEmpty {
            let suffix = String(Slugify.slug(cid).suffix(6))
            return "\(baseSlug)-\(suffix)"
        }
        return baseSlug
    }

    /// `channelDirName` for a resolved channel — used at "Add channel" time.
    static func channelDirName(resolved: ResolvedChannel) -> String {
        let baseSlug = Slugify.slug(resolved.name.isEmpty ? "unknown-channel" : resolved.name)
        if let cid = resolved.channelId, !cid.isEmpty {
            let suffix = String(Slugify.slug(cid).suffix(6))
            return "\(baseSlug)-\(suffix)"
        }
        return baseSlug
    }

    /// <YYYY-MM-DD>-<title-slug>-<11charid>.md
    static func videoFileName(meta: VideoMetadata) -> String {
        let date: String
        if let upload = meta.uploadDate, upload.count == 8 {
            let chars = Array(upload)
            date = "\(String(chars[0..<4]))-\(String(chars[4..<6]))-\(String(chars[6..<8]))"
        } else {
            date = DateFormatter.iso8601Date.string(from: Date())
        }
        let titleSlug = Slugify.slug(meta.title ?? "")
        return "\(date)-\(titleSlug)-\(meta.id).md"
    }
}
