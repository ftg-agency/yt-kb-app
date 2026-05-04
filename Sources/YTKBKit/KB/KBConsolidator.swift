import Foundation

/// One-time KB-layout migration. Older versions (and the legacy `yt-kb.py`
/// script) wrote channel folders with `<slug>-<id-suffix>` names, while the
/// current Swift app writes plain `<slug>`. After the slug fix, users ended up
/// with duplicate folders for the same channel.
///
/// `KBConsolidator` walks the KB root, finds every folder belonging to a
/// tracked channel via `AutoDiscovery`, and converges all of them onto a single
/// canonical `Slugify.slug(channel.name)` folder — renaming when there's only
/// one source, or merging via `KBMigrator` when there are multiple. The
/// resolved folder name is then pinned on `TrackedChannel.folderName` so future
/// polls don't drift again.
///
/// Runs once per install (gated by `Settings.kbConsolidationVersion`). Safe to
/// re-run: `KBMigrator` is idempotent on deterministic filenames.
package enum KBConsolidator {

    /// One channel's outcome after consolidation.
    package struct ChannelOutcome {
        package let channelURL: String
        package let folderName: String?  // canonical folder; nil if nothing on disk
        package let merged: Int          // number of source folders merged into target (0 = no-op or rename only)
        package let renamed: Bool        // true when single source folder was renamed to canonical
        package let mergeErrors: Int     // file-level failures reported by KBMigrator across all merged sources
    }

    package struct Report {
        package var outcomes: [ChannelOutcome] = []
        package var renamedFolders: Int { outcomes.filter(\.renamed).count }
        package var mergedFolders: Int { outcomes.reduce(0) { $0 + $1.merged } }
        package var pinnedChannels: Int { outcomes.filter { $0.folderName != nil }.count }
        package var totalErrors: Int { outcomes.reduce(0) { $0 + $1.mergeErrors } }
    }

    /// Run the consolidation. Pure: doesn't touch persistent storage. Caller is
    /// responsible for applying `outcomes` to `ChannelStore` via `updateChannel`.
    package static func consolidate(kbRoot: URL, channels: [TrackedChannel]) -> Report {
        let fm = FileManager.default
        guard fm.fileExists(atPath: kbRoot.path) else { return Report() }

        let discovered = AutoDiscovery.discover(in: kbRoot)
        // Group by normalized URL — a channel may appear in 2+ folders.
        var byURL: [String: [DiscoveredChannel]] = [:]
        for d in discovered {
            byURL[normalizeURL(d.url), default: []].append(d)
        }

        var report = Report()
        for channel in channels {
            let key = normalizeURL(channel.url)
            let matches = byURL[key] ?? []
            let canonical = Slugify.slug(channel.name.isEmpty ? "unknown-channel" : channel.name)
            let targetDir = kbRoot.appendingPathComponent(canonical)

            if matches.isEmpty {
                // Nothing on disk for this channel; nothing to consolidate.
                // Leave folderName untouched so a future poll can pin it.
                report.outcomes.append(ChannelOutcome(
                    channelURL: channel.url,
                    folderName: channel.folderName,
                    merged: 0,
                    renamed: false,
                    mergeErrors: 0
                ))
                continue
            }

            // Single folder, already at canonical — just pin and move on.
            if matches.count == 1, matches[0].folderName == canonical {
                report.outcomes.append(ChannelOutcome(
                    channelURL: channel.url,
                    folderName: canonical,
                    merged: 0,
                    renamed: false,
                    mergeErrors: 0
                ))
                continue
            }

            // Single folder elsewhere — try a cheap rename, fall back to merge
            // if the canonical target also exists (race / leftover empty dir).
            if matches.count == 1 {
                let src = kbRoot.appendingPathComponent(matches[0].folderName)
                if !fm.fileExists(atPath: targetDir.path) {
                    do {
                        try fm.moveItem(at: src, to: targetDir)
                        Logger.shared.info("KBConsolidator: renamed \(matches[0].folderName) → \(canonical)")
                        report.outcomes.append(ChannelOutcome(
                            channelURL: channel.url,
                            folderName: canonical,
                            merged: 0,
                            renamed: true,
                            mergeErrors: 0
                        ))
                        continue
                    } catch {
                        Logger.shared.warn("KBConsolidator: rename failed (\(matches[0].folderName) → \(canonical)): \(error). Falling back to merge.")
                    }
                }
                let mergeReport = KBMigrator.migrate(from: src, to: targetDir)
                Logger.shared.info("KBConsolidator: merged \(matches[0].folderName) → \(canonical) (copied=\(mergeReport.copied) skipped=\(mergeReport.skipped) failed=\(mergeReport.failed.count))")
                report.outcomes.append(ChannelOutcome(
                    channelURL: channel.url,
                    folderName: canonical,
                    merged: 1,
                    renamed: false,
                    mergeErrors: mergeReport.failed.count
                ))
                continue
            }

            // Multiple folders for the same channel — merge each non-canonical
            // source into the canonical target. KBMigrator skips dupes by name.
            try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            var mergedCount = 0
            var failedFiles = 0
            for match in matches where match.folderName != canonical {
                let src = kbRoot.appendingPathComponent(match.folderName)
                let r = KBMigrator.migrate(from: src, to: targetDir)
                Logger.shared.info("KBConsolidator: merged \(match.folderName) → \(canonical) (copied=\(r.copied) skipped=\(r.skipped) failed=\(r.failed.count))")
                mergedCount += 1
                failedFiles += r.failed.count
            }
            report.outcomes.append(ChannelOutcome(
                channelURL: channel.url,
                folderName: canonical,
                merged: mergedCount,
                renamed: false,
                mergeErrors: failedFiles
            ))
        }
        return report
    }

    /// Loose URL match: trim whitespace and a single trailing slash. Avoids
    /// host-case quibbles by leaving them alone (yt-dlp emits canonical URLs
    /// for both index.md and TrackedChannel, so they should already agree).
    package static func normalizeURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Look up an existing channel folder in `kbRoot` by URL. Used by the
    /// "add channel" flow so we adopt pre-existing folders instead of creating
    /// a duplicate clean-slug sibling on first poll.
    package static func existingFolderName(forURL url: String, in kbRoot: URL) -> String? {
        let key = normalizeURL(url)
        for d in AutoDiscovery.discover(in: kbRoot) where normalizeURL(d.url) == key {
            return d.folderName
        }
        return nil
    }
}
