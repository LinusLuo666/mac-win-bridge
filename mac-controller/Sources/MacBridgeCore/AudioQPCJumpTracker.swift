public enum AudioQPCJumpDirection: String, Equatable, Sendable {
    case forward
    case backwardOrReset
}

public struct AudioQPCJump: Equatable, Sendable {
    public let direction: AudioQPCJumpDirection
    public let previousPosition: UInt64
    public let currentPosition: UInt64
    public let actualDelta: UInt64?
    public let expectedDelta: UInt64
}

public struct AudioQPCJumpTracker: Sendable {
    private var previousPosition: UInt64?
    private var previousDuration: UInt64?

    public init() {}

    public mutating func record(
        position: UInt64,
        frameCount: Int,
        sampleRate: Int
    ) -> AudioQPCJump? {
        let duration = Self.duration100Nanoseconds(
            frameCount: frameCount,
            sampleRate: sampleRate
        )
        defer {
            previousPosition = position
            previousDuration = duration
        }

        guard let previousPosition,
              let expectedDelta = previousDuration else {
            return nil
        }
        guard position > previousPosition else {
            return AudioQPCJump(
                direction: .backwardOrReset,
                previousPosition: previousPosition,
                currentPosition: position,
                actualDelta: nil,
                expectedDelta: expectedDelta
            )
        }

        let actualDelta = position - previousPosition
        let tolerance = max(10_000, expectedDelta / 2)
        guard actualDelta > expectedDelta,
              actualDelta - expectedDelta > tolerance else {
            return nil
        }

        return AudioQPCJump(
            direction: .forward,
            previousPosition: previousPosition,
            currentPosition: position,
            actualDelta: actualDelta,
            expectedDelta: expectedDelta
        )
    }

    private static func duration100Nanoseconds(frameCount: Int, sampleRate: Int) -> UInt64 {
        guard frameCount > 0, sampleRate > 0 else {
            return 0
        }
        return UInt64(frameCount) * 10_000_000 / UInt64(sampleRate)
    }
}
