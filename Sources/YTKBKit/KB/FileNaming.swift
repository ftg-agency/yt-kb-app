import Foundation

package enum FileNaming {
    /// channel-slug (clean kebab-case, no id suffix).
    package static func channelDirName(meta: VideoMetadata) -> String {
        let name = meta.displayChannel.isEmpty ? "unknown-channel" : meta.displayChannel
        return Slugify.slug(name)
    }

    /// `channelDirName` for a resolved channel — used at "Add channel" time.
    static func channelDirName(resolved: ResolvedChannel) -> String {
        Slugify.slug(resolved.name.isEmpty ? "unknown-channel" : resolved.name)
    }

    /// <YYYY-MM-DD>-<title-slug>-<11charid>.md
    package static func videoFileName(meta: VideoMetadata) -> String {
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
