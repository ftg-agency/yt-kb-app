import Foundation
import YTKBKit

@MainActor
func retryProcessorTests() {
    TestHarness.test("Entry without lastAttempt is eligible") {
        let entry = makeEntry(lastAttempt: nil, attempts: 0)
        try expectEq(RetryProcessor.eligibleEntries([entry]).count, 1)
    }

    TestHarness.test("Entry within backoff is not eligible") {
        let now = Date()
        let entry = makeEntry(lastAttempt: now.addingTimeInterval(-3 * 3600), attempts: 1)
        try expectTrue(RetryProcessor.eligibleEntries([entry], now: now).isEmpty)
    }

    TestHarness.test("Entry past backoff is eligible") {
        let now = Date()
        let entry = makeEntry(lastAttempt: now.addingTimeInterval(-7 * 3600), attempts: 1)
        try expectEq(RetryProcessor.eligibleEntries([entry], now: now).count, 1)
    }

    TestHarness.test("Permanent entry never eligible") {
        let now = Date()
        var entry = makeEntry(lastAttempt: now.addingTimeInterval(-30 * 86400), attempts: 10)
        entry.status = "permanent_no_subs"
        try expectTrue(RetryProcessor.eligibleEntries([entry], now: now).isEmpty)
    }

    TestHarness.test("shouldMarkPermanent requires both 7-day age and 7+ attempts") {
        let now = Date()
        let young = makeEntry(firstSeen: now.addingTimeInterval(-10 * 86400), attempts: 3)
        try expectFalse(RetryProcessor.shouldMarkPermanent(young, now: now))

        let recent = makeEntry(firstSeen: now.addingTimeInterval(-2 * 86400), attempts: 10)
        try expectFalse(RetryProcessor.shouldMarkPermanent(recent, now: now))

        let both = makeEntry(firstSeen: now.addingTimeInterval(-10 * 86400), attempts: 7)
        try expectTrue(RetryProcessor.shouldMarkPermanent(both, now: now))
    }

    TestHarness.test("eligibleEntries preserves order, filters in-window") {
        let now = Date()
        let a = makeEntry(videoId: "AAAAAAAAAAA", lastAttempt: now.addingTimeInterval(-7 * 3600), attempts: 1)
        let b = makeEntry(videoId: "BBBBBBBBBBB", lastAttempt: nil, attempts: 0)
        let c = makeEntry(videoId: "CCCCCCCCCCC", lastAttempt: now.addingTimeInterval(-2 * 3600), attempts: 1)
        let result = RetryProcessor.eligibleEntries([a, b, c], now: now)
        try expectEq(result.map(\.videoId), ["AAAAAAAAAAA", "BBBBBBBBBBB"])
    }
}

private func makeEntry(
    videoId: String = "TEST1234567",
    firstSeen: Date = Date().addingTimeInterval(-86400),
    lastAttempt: Date? = nil,
    attempts: Int = 1
) -> RetryQueueEntry {
    RetryQueueEntry(
        channelURL: "https://www.youtube.com/@test",
        videoId: videoId,
        videoTitle: "test",
        firstSeen: firstSeen,
        lastAttempt: lastAttempt,
        attempts: attempts,
        status: "no_subs"
    )
}
