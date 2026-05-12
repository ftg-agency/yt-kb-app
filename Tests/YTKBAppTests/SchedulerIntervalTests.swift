import Foundation
import YTKBKit

@MainActor
func schedulerIntervalTests() {
    TestHarness.test("isDueForScheduledPoll: never-polled channel is due") {
        let ch = makeChannel(url: "a", lastPolledAt: nil)
        try expectTrue(ch.isDueForScheduledPoll(globalSeconds: 3600))
    }

    TestHarness.test("isDueForScheduledPoll: recent poll is not due") {
        let ch = makeChannel(url: "a", lastPolledAt: Date().addingTimeInterval(-1800))  // 30 min ago
        try expectFalse(ch.isDueForScheduledPoll(globalSeconds: 3600))
    }

    TestHarness.test("isDueForScheduledPoll: poll older than interval is due") {
        let ch = makeChannel(url: "a", lastPolledAt: Date().addingTimeInterval(-7200))  // 2h ago
        try expectTrue(ch.isDueForScheduledPoll(globalSeconds: 3600))
    }

    TestHarness.test("ChannelProgress.fraction is bounded to [0, 1]") {
        try expectEq(ChannelProgress(phase: .processing, current: 0, total: 10).fraction, 0.0)
        try expectEq(ChannelProgress(phase: .processing, current: 5, total: 10).fraction, 0.5)
        try expectEq(ChannelProgress(phase: .processing, current: 10, total: 10).fraction, 1.0)
        // Defensive: current > total clamps to 1.0
        try expectEq(ChannelProgress(phase: .processing, current: 15, total: 10).fraction, 1.0)
        // Total = 0 returns 0
        try expectEq(ChannelProgress(phase: .resolving, current: 0, total: 0).fraction, 0.0)
    }
}

private func makeChannel(url: String, lastPolledAt: Date? = nil) -> TrackedChannel {
    TrackedChannel(
        url: url,
        channelId: nil,
        name: url,
        addedAt: Date(),
        lastPolledAt: lastPolledAt,
        lastPollStatus: nil,
        lastPollError: nil,
        enabled: true
    )
}
