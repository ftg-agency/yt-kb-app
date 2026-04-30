import Foundation

@MainActor
func runAll() {
    TestHarness.suite("Parsers", parserTests)
    TestHarness.suite("SubsPlanner", plannerTests)
    TestHarness.suite("Slugify", slugifyTests)
    TestHarness.suite("KBScanner", scannerTests)
    TestHarness.suite("MarkdownRenderer", markdownTests)
    TestHarness.suite("RetryProcessor", retryProcessorTests)
    TestHarness.suite("ChannelResolver", channelResolverTests)
    TestHarness.suite("KBMigrator", migratorTests)
    TestHarness.suite("Scheduler/Interval", schedulerIntervalTests)
    exit(Int32(TestHarness.summary()))
}

DispatchQueue.main.async { runAll() }
RunLoop.main.run()
