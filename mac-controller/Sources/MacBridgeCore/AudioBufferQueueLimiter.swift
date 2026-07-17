import Foundation

public final class AudioBufferQueueLimiter: @unchecked Sendable {
    private let condition = NSCondition()
    private let maximumPendingBuffers: Int
    private var pendingBuffers = 0
    private var stopped = false

    public init(maximumPendingBuffers: Int) {
        precondition(maximumPendingBuffers > 0, "maximumPendingBuffers must be positive")
        self.maximumPendingBuffers = maximumPendingBuffers
    }

    public func tryReserve() -> Bool {
        condition.lock()
        defer { condition.unlock() }

        guard !stopped, pendingBuffers < maximumPendingBuffers else {
            return false
        }

        pendingBuffers += 1
        return true
    }

    public func waitForSlot() -> Bool {
        condition.lock()
        defer { condition.unlock() }

        while !stopped && pendingBuffers >= maximumPendingBuffers {
            condition.wait()
        }

        guard !stopped else {
            return false
        }

        pendingBuffers += 1
        return true
    }

    public func release() {
        condition.lock()
        defer { condition.unlock() }

        guard pendingBuffers > 0 else {
            return
        }

        pendingBuffers -= 1
        condition.signal()
    }

    public func stop() {
        condition.lock()
        defer { condition.unlock() }

        stopped = true
        condition.broadcast()
    }
}
