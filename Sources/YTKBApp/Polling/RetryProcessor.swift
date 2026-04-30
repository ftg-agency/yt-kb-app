import Foundation

/// Retry-queue processing rules (per spec §3.4):
/// - For each entry older than `minBackoffSeconds` since `last_attempt`:
///   - re-run try_subs cascade
///   - on success: write .md, remove from queue
///   - on no_subs: increment attempts, update last_attempt
/// - If `first_seen` > 7 days AND attempts >= 7 → mark `permanent_no_subs`,
///   keep visible in queue for UI but stop retrying.
enum RetryProcessor {
    static let minBackoffSeconds: TimeInterval = 6 * 3600
    static let maxAttempts = 7
    static let permanentAfterDays: TimeInterval = 7 * 86400

    static func eligibleEntries(_ queue: [RetryQueueEntry], now: Date = Date()) -> [RetryQueueEntry] {
        queue.filter { entry in
            if entry.status == "permanent_no_subs" { return false }
            if let last = entry.lastAttempt {
                return now.timeIntervalSince(last) >= minBackoffSeconds
            }
            return true  // never attempted yet
        }
    }

    static func shouldMarkPermanent(_ entry: RetryQueueEntry, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(entry.firstSeen)
        return age >= permanentAfterDays && entry.attempts >= maxAttempts
    }
}
