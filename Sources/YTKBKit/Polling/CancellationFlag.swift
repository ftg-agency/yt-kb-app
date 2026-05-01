import Foundation

/// Thread-safe cancellation flag for cooperative cancellation across the
/// PollingCoordinator → PollOperation → YTDLPRunner pipeline. We can't use
/// Swift's native Task cancellation cleanly here because YTDLPRunner spawns
/// detached Tasks for subprocess work, which lose the parent's cancellation
/// context.
package final class CancellationFlag: @unchecked Sendable {
    private var _cancelled = false
    private let lock = NSLock()

    package init() {}

    package var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    package func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }

    package func reset() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = false
    }
}
