import Foundation

public enum AudioLatencySetting {
    public static let minimumMilliseconds = 10
    public static let maximumMilliseconds = 120
    public static let defaultMilliseconds = 50

    public static func parse(_ value: String) -> Int? {
        guard let milliseconds = Int(value),
              (minimumMilliseconds...maximumMilliseconds).contains(milliseconds) else {
            return nil
        }
        return milliseconds
    }
}

public enum PCMOutputJitterBufferState: Equatable, Sendable {
    case priming
    case playing
    case stopped
}

public struct PCMOutputJitterBufferThresholds: Equatable, Sendable {
    public let requestedLatencyMilliseconds: Int
    public let sampleRate: Int
    public let targetSampleFrames: Int
    public let maximumSampleFrames: Int
}

public struct PCMOutputJitterBufferEnqueueResult: Equatable, Sendable {
    public let trimmedOutputBuffers: Int
    public let trimmedOutputSampleFrames: Int
}

public struct PCMOutputJitterBufferSnapshot: Equatable, Sendable {
    public let state: PCMOutputJitterBufferState
    public let requestedLatencyMilliseconds: Int
    public let effectiveTargetSampleFrames: Int?
    public let maximumSampleFrames: Int?
    public let queuedOutputBuffers: Int
    public let queuedOutputSampleFrames: Int
    public let scheduledPendingSampleFrames: Int
    public let trimmedOutputBuffers: Int
    public let trimmedOutputSampleFrames: Int
    public let underrunCount: Int
    public let rebufferCount: Int
    public let totalRebufferDurationMilliseconds: Int
    public let maximumQueuedSampleFrames: Int
}

public final class PCMOutputJitterBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private let requestedLatencyMilliseconds: Int
    private var configuredThresholds: PCMOutputJitterBufferThresholds?
    private var state = PCMOutputJitterBufferState.priming
    private var queue: [ReblockedPCMOutput] = []
    private var queuedOutputSampleFrames = 0
    private var scheduledPendingSampleFrames = 0
    private var trimmedOutputBuffers = 0
    private var trimmedOutputSampleFrames = 0
    private var underrunCount = 0
    private var rebufferCount = 0
    private var totalRebufferDurationMilliseconds = 0
    private var maximumQueuedSampleFrames = 0
    private var rebufferStartedAt: Date?

    public init(requestedLatencyMilliseconds: Int) {
        precondition(
            (AudioLatencySetting.minimumMilliseconds...AudioLatencySetting.maximumMilliseconds)
                .contains(requestedLatencyMilliseconds),
            "audio latency must be between 10 and 120 milliseconds"
        )
        self.requestedLatencyMilliseconds = requestedLatencyMilliseconds
    }

    public static func thresholds(
        sampleRate: Int,
        requestedLatencyMilliseconds: Int,
        blockSampleFrames: Int = PCMReblocker.outputFrameCount,
        marginMilliseconds: Int = 20
    ) -> PCMOutputJitterBufferThresholds {
        precondition(sampleRate > 0, "sample rate must be positive")
        precondition(blockSampleFrames > 0, "block sample frames must be positive")
        precondition(marginMilliseconds >= 0, "margin milliseconds must not be negative")
        precondition(
            (AudioLatencySetting.minimumMilliseconds...AudioLatencySetting.maximumMilliseconds)
                .contains(requestedLatencyMilliseconds),
            "audio latency must be between 10 and 120 milliseconds"
        )

        let requestedFrames = Int(
            (Double(sampleRate) * Double(requestedLatencyMilliseconds) / 1_000).rounded()
        )
        let marginFrames = Int(
            (Double(sampleRate) * Double(marginMilliseconds) / 1_000).rounded()
        )
        let targetFrames = roundUp(requestedFrames, multiple: blockSampleFrames)
        let roundedMarginFrames = roundUp(marginFrames, multiple: blockSampleFrames)
        return PCMOutputJitterBufferThresholds(
            requestedLatencyMilliseconds: requestedLatencyMilliseconds,
            sampleRate: sampleRate,
            targetSampleFrames: targetFrames,
            maximumSampleFrames: targetFrames + roundedMarginFrames
        )
    }

    public func enqueue(
        _ outputs: [ReblockedPCMOutput],
        at date: Date = Date()
    ) -> PCMOutputJitterBufferEnqueueResult {
        condition.lock()
        defer { condition.unlock() }

        guard state != .stopped else {
            return PCMOutputJitterBufferEnqueueResult(
                trimmedOutputBuffers: 0,
                trimmedOutputSampleFrames: 0
            )
        }

        for output in outputs {
            let sampleRate = Int(output.buffer.format.sampleRate.rounded())
            if configuredThresholds == nil {
                configuredThresholds = Self.thresholds(
                    sampleRate: sampleRate,
                    requestedLatencyMilliseconds: requestedLatencyMilliseconds
                )
            }
            precondition(
                configuredThresholds?.sampleRate == sampleRate,
                "jitter buffer sample rate changed"
            )

            let sampleFrames = Int(output.buffer.frameLength)
            precondition(sampleFrames > 0, "jitter buffer output must not be empty")
            queue.append(output)
            queuedOutputSampleFrames += sampleFrames
        }

        maximumQueuedSampleFrames = max(
            maximumQueuedSampleFrames,
            queuedOutputSampleFrames
        )

        var trimmedBuffersDelta = 0
        var trimmedSampleFramesDelta = 0
        if let configuredThresholds,
           queuedOutputSampleFrames + scheduledPendingSampleFrames
                > configuredThresholds.maximumSampleFrames {
            while !queue.isEmpty,
                  queuedOutputSampleFrames + scheduledPendingSampleFrames
                    > configuredThresholds.targetSampleFrames {
                let removed = queue.removeFirst()
                let removedFrames = Int(removed.buffer.frameLength)
                queuedOutputSampleFrames -= removedFrames
                trimmedBuffersDelta += 1
                trimmedSampleFramesDelta += removedFrames
            }
            trimmedOutputBuffers += trimmedBuffersDelta
            trimmedOutputSampleFrames += trimmedSampleFramesDelta
        }

        if let configuredThresholds,
           state == .priming,
           queuedOutputSampleFrames >= configuredThresholds.targetSampleFrames {
            state = .playing
            if let rebufferStartedAt {
                totalRebufferDurationMilliseconds += max(
                    0,
                    Int((date.timeIntervalSince(rebufferStartedAt) * 1_000).rounded())
                )
                self.rebufferStartedAt = nil
            }
        }

        if !outputs.isEmpty {
            condition.broadcast()
        }
        return PCMOutputJitterBufferEnqueueResult(
            trimmedOutputBuffers: trimmedBuffersDelta,
            trimmedOutputSampleFrames: trimmedSampleFramesDelta
        )
    }

    public func waitForNextToSchedule() -> ReblockedPCMOutput? {
        condition.lock()
        defer { condition.unlock() }

        while state != .stopped {
            if state == .playing, !queue.isEmpty {
                let output = queue.removeFirst()
                let sampleFrames = Int(output.buffer.frameLength)
                queuedOutputSampleFrames -= sampleFrames
                scheduledPendingSampleFrames += sampleFrames
                return output
            }
            condition.wait()
        }
        return nil
    }

    public func completeScheduled(sampleFrames: Int, at date: Date = Date()) {
        condition.lock()
        defer { condition.unlock() }

        guard state != .stopped else {
            return
        }
        precondition(sampleFrames > 0, "completed sample frames must be positive")
        precondition(
            sampleFrames <= scheduledPendingSampleFrames,
            "completed more sample frames than scheduled"
        )
        scheduledPendingSampleFrames -= sampleFrames

        if state == .playing,
           scheduledPendingSampleFrames == 0,
           queue.isEmpty {
            state = .priming
            underrunCount += 1
            rebufferCount += 1
            rebufferStartedAt = date
        }
        condition.broadcast()
    }

    public func snapshot() -> PCMOutputJitterBufferSnapshot {
        condition.lock()
        defer { condition.unlock() }

        return PCMOutputJitterBufferSnapshot(
            state: state,
            requestedLatencyMilliseconds: requestedLatencyMilliseconds,
            effectiveTargetSampleFrames: configuredThresholds?.targetSampleFrames,
            maximumSampleFrames: configuredThresholds?.maximumSampleFrames,
            queuedOutputBuffers: queue.count,
            queuedOutputSampleFrames: queuedOutputSampleFrames,
            scheduledPendingSampleFrames: scheduledPendingSampleFrames,
            trimmedOutputBuffers: trimmedOutputBuffers,
            trimmedOutputSampleFrames: trimmedOutputSampleFrames,
            underrunCount: underrunCount,
            rebufferCount: rebufferCount,
            totalRebufferDurationMilliseconds: totalRebufferDurationMilliseconds,
            maximumQueuedSampleFrames: maximumQueuedSampleFrames
        )
    }

    public func stop() {
        condition.lock()
        state = .stopped
        queue.removeAll(keepingCapacity: false)
        queuedOutputSampleFrames = 0
        scheduledPendingSampleFrames = 0
        rebufferStartedAt = nil
        condition.broadcast()
        condition.unlock()
    }

    private static func roundUp(_ value: Int, multiple: Int) -> Int {
        guard value > 0 else {
            return 0
        }
        return ((value + multiple - 1) / multiple) * multiple
    }
}
