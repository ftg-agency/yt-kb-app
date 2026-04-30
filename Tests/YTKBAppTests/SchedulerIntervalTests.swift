import Foundation
import YTKBKit

@MainActor
func schedulerIntervalTests() {
    TestHarness.test("effectiveTickInterval falls back to global when no per-channel overrides") {
        let chans = [
            makeChannel(url: "a", interval: nil),
            makeChannel(url: "b", interval: nil)
        ]
        let interval = PollingScheduler.effectiveTickInterval(channels: chans, globalSeconds: 10800)
        try expectEq(interval, 10800)
    }

    TestHarness.test("effectiveTickInterval uses min when per-channel is faster than global") {
        let chans = [
            makeChannel(url: "a", interval: nil),       // uses global = 10800
            makeChannel(url: "b", interval: 3600)       // hourly
        ]
        let interval = PollingScheduler.effectiveTickInterval(channels: chans, globalSeconds: 10800)
        try expectEq(interval, 3600)
    }

    TestHarness.test("effectiveTickInterval ignores manual-only channels") {
        let chans = [
            makeChannel(url: "a", interval: 0),  // manual only
            makeChannel(url: "b", interval: nil)
        ]
        let interval = PollingScheduler.effectiveTickInterval(channels: chans, globalSeconds: 10800)
        try expectEq(interval, 10800)
    }

    TestHarness.test("isDueForScheduledPoll: never-polled channel is due") {
        let ch = makeChannel(url: "a", interval: nil, lastPolledAt: nil)
        try expectTrue(ch.isDueForScheduledPoll(globalSeconds: 3600))
    }

    TestHarness.test("isDueForScheduledPoll: recent poll is not due") {
        let ch = makeChannel(url: "a", interval: nil, lastPolledAt: Date().addingTimeInterval(-1800))  // 30 min ago
        try expectFalse(ch.isDueForScheduledPoll(globalSeconds: 3600))
    }

    TestHarness.test("isDueForScheduledPoll: poll older than interval is due") {
        let ch = makeChannel(url: "a", interval: nil, lastPolledAt: Date().addingTimeInterval(-7200))  // 2h ago
        try expectTrue(ch.isDueForScheduledPoll(globalSeconds: 3600))
    }

    TestHarness.test("isDueForScheduledPoll: per-channel hourly overrides slower global") {
        let ch = makeChannel(url: "a", interval: 3600, lastPolledAt: Date().addingTimeInterval(-3700))  // 1h+ ago
        // Global says every 24h (so wouldn't be due) but per-channel says hourly (so IS due)
        try expectTrue(ch.isDueForScheduledPoll(globalSeconds: 86400))
    }

    TestHarness.test("isDueForScheduledPoll: manual-only channel never due") {
        let ch = makeChannel(url: "a", interval: 0, lastPolledAt: Date().addingTimeInterval(-100 * 86400))
        try expectFalse(ch.isDueForScheduledPoll(globalSeconds: 3600))
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

private func makeChannel(url: String, interval: Int?, lastPolledAt: Date? = nil) -> TrackedChannel {
    TrackedChannel(
        url: url,
        channelId: nil,
        name: url,
        addedAt: Date(),
        lastPolledAt: lastPolledAt,
        lastPollStatus: nil,
        lastPollError: nil,
        enabled: true,
        pollIntervalSeconds: interval
    )
}
