import Foundation

public enum LatestFramePutResult: Equatable, Sendable {
    case stored
    case replaced
    case stopped
}

public final class LatestFrameBuffer<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var latest: Element?
    private var stopped = false

    public init() {}

    @discardableResult
    public func put(_ value: Element) -> LatestFramePutResult {
        condition.lock()
        defer { condition.unlock() }

        guard !stopped else {
            return .stopped
        }

        let result: LatestFramePutResult = latest == nil ? .stored : .replaced
        latest = value
        condition.signal()
        return result
    }

    public func waitForLatest() -> Element? {
        condition.lock()
        defer { condition.unlock() }

        while !stopped && latest == nil {
            condition.wait()
        }

        guard !stopped else {
            return nil
        }

        let value = latest
        latest = nil
        return value
    }

    public func stop() {
        condition.lock()
        stopped = true
        latest = nil
        condition.broadcast()
        condition.unlock()
    }
}
