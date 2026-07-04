import Foundation

public struct ReconnectBackoff: Equatable {
    private var attempt = 0
    private let maximumDelay: TimeInterval

    public init(maximumDelay: TimeInterval = 10) {
        self.maximumDelay = maximumDelay
    }

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(pow(2, Double(attempt)), maximumDelay)
        attempt += 1
        return delay
    }

    public mutating func reset() {
        attempt = 0
    }
}
