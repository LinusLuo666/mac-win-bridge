import Foundation

public enum LatestFramePutResult: Equatable, Sendable {
    case stored
    case replaced
    case stopped
}

public struct LatestFramePutOutcome<Element> {
    public let result: LatestFramePutResult
    public let replaced: Element?
}

public final class LatestFrameBuffer<Element>: @unchecked Sendable {
    private let condition = NSCondition()
    private var latest: Element?
    private var stopped = false

    public init() {}

    @discardableResult
    public func put(_ value: Element) -> LatestFramePutResult {
        putReturningReplaced(value).result
    }

    public func putReturningReplaced(_ value: Element) -> LatestFramePutOutcome<Element> {
        condition.lock()
        defer { condition.unlock() }

        guard !stopped else {
            return LatestFramePutOutcome(result: .stopped, replaced: nil)
        }

        let replaced = latest
        let result: LatestFramePutResult = replaced == nil ? .stored : .replaced
        latest = value
        condition.signal()
        return LatestFramePutOutcome(result: result, replaced: replaced)
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
