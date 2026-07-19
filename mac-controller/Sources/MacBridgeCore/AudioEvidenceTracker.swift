import Foundation

public struct AudioEvidenceWindowBoundary: Equatable, Sendable {
    public let start: Date
    public let end: Date
}

public enum AudioEvidenceClock {
    public static func alignedWindow(
        containing date: Date,
        duration: TimeInterval
    ) -> AudioEvidenceWindowBoundary {
        precondition(duration > 0, "window duration must be positive")
        let startInterval = floor(date.timeIntervalSince1970 / duration) * duration
        let start = Date(timeIntervalSince1970: startInterval)
        return AudioEvidenceWindowBoundary(
            start: start,
            end: start.addingTimeInterval(duration)
        )
    }

    public static func timestamp(
        _ date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

public struct AudioEvidenceWindowSnapshot: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let receivedFrames: Int
    public let scheduledFrames: Int
    public let completedFrames: Int
    public let droppedFrames: Int
    public let frameCountDistribution: [Int: Int]
    public let qpcJumps: Int
    public let maximumQpcDelta: UInt64?
    public let maximumArrivalGapMilliseconds: Int
}

public struct AudioEvidenceWindowTracker: Sendable {
    private var windowStart: Date
    private var receivedFrames = 0
    private var scheduledFrames = 0
    private var completedFrames = 0
    private var droppedFrames = 0
    private var frameCountDistribution: [Int: Int] = [:]
    private var qpcJumps = 0
    private var maximumQpcDelta: UInt64?
    private var previousArrival: Date?
    private var maximumArrivalGapMilliseconds = 0

    public init(windowStart: Date) {
        self.windowStart = windowStart
    }

    public mutating func recordReceived(frameCount: Int, dropped: Bool, at date: Date) {
        receivedFrames += 1
        if dropped {
            droppedFrames += 1
        }
        frameCountDistribution[frameCount, default: 0] += 1

        if let previousArrival {
            let gap = max(0, date.timeIntervalSince(previousArrival))
            maximumArrivalGapMilliseconds = max(
                maximumArrivalGapMilliseconds,
                Int((gap * 1_000).rounded())
            )
        }
        previousArrival = date
    }

    public mutating func recordScheduled(qpcJumpActualDelta: UInt64?) {
        scheduledFrames += 1
        guard let qpcJumpActualDelta else {
            return
        }
        qpcJumps += 1
        maximumQpcDelta = max(maximumQpcDelta ?? 0, qpcJumpActualDelta)
    }

    public mutating func recordCompleted() {
        completedFrames += 1
    }

    public mutating func snapshotAndReset(windowEnd: Date) -> AudioEvidenceWindowSnapshot {
        let snapshot = AudioEvidenceWindowSnapshot(
            start: windowStart,
            end: windowEnd,
            receivedFrames: receivedFrames,
            scheduledFrames: scheduledFrames,
            completedFrames: completedFrames,
            droppedFrames: droppedFrames,
            frameCountDistribution: frameCountDistribution,
            qpcJumps: qpcJumps,
            maximumQpcDelta: maximumQpcDelta,
            maximumArrivalGapMilliseconds: maximumArrivalGapMilliseconds
        )

        windowStart = windowEnd
        receivedFrames = 0
        scheduledFrames = 0
        completedFrames = 0
        droppedFrames = 0
        frameCountDistribution.removeAll(keepingCapacity: true)
        qpcJumps = 0
        maximumQpcDelta = nil
        maximumArrivalGapMilliseconds = 0
        return snapshot
    }
}

public struct AudioPipelineEvidenceWindowSnapshot: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let receivedInputBuffers: Int
    public let receivedInputSampleFrames: Int
    public let overwrittenInputBuffers: Int
    public let overwrittenInputSampleFrames: Int
    public let reblockedOutputBuffers: Int
    public let reblockedOutputSampleFrames: Int
    public let scheduledOutputBuffers: Int
    public let scheduledOutputSampleFrames: Int
    public let completedOutputBuffers: Int
    public let completedOutputSampleFrames: Int
    public let carrySampleFrames: Int
    public let inputFrameCountDistribution: [Int: Int]
    public let qpcJumps: Int
    public let maximumQpcDelta: UInt64?
    public let maximumArrivalGapMilliseconds: Int
    public let outputSourceSpanCount: Int
    public let firstOutputStartQPCPosition: UInt64?
    public let lastOutputEndQPCPosition: UInt64?
    public let configuredLatencyMilliseconds: Int?
    public let effectiveTargetSampleFrames: Int?
    public let queuedOutputBuffers: Int
    public let queuedOutputSampleFrames: Int
    public let scheduledPendingSampleFrames: Int
    public let trimmedOutputBuffers: Int
    public let trimmedOutputSampleFrames: Int
    public let underrunCount: Int
    public let rebufferCount: Int
    public let rebufferDurationMilliseconds: Int
    public let maximumQueuedSampleFrames: Int
}

public struct AudioPipelineEvidenceWindowTracker: Sendable {
    private var windowStart: Date
    private var receivedInputBuffers = 0
    private var receivedInputSampleFrames = 0
    private var overwrittenInputBuffers = 0
    private var overwrittenInputSampleFrames = 0
    private var reblockedOutputBuffers = 0
    private var reblockedOutputSampleFrames = 0
    private var scheduledOutputBuffers = 0
    private var scheduledOutputSampleFrames = 0
    private var completedOutputBuffers = 0
    private var completedOutputSampleFrames = 0
    private var carrySampleFrames = 0
    private var inputFrameCountDistribution: [Int: Int] = [:]
    private var qpcJumps = 0
    private var maximumQpcDelta: UInt64?
    private var previousArrival: Date?
    private var maximumArrivalGapMilliseconds = 0
    private var outputSourceSpanCount = 0
    private var firstOutputStartQPCPosition: UInt64?
    private var lastOutputEndQPCPosition: UInt64?
    private var configuredLatencyMilliseconds: Int?
    private var effectiveTargetSampleFrames: Int?
    private var queuedOutputBuffers = 0
    private var queuedOutputSampleFrames = 0
    private var scheduledPendingSampleFrames = 0
    private var trimmedOutputBuffers = 0
    private var trimmedOutputSampleFrames = 0
    private var underrunCount = 0
    private var rebufferCount = 0
    private var rebufferDurationMilliseconds = 0
    private var maximumQueuedSampleFrames = 0

    public init(windowStart: Date) {
        self.windowStart = windowStart
    }

    public mutating func recordInput(
        sampleFrameCount: Int,
        overwrittenSampleFrameCount: Int,
        qpcJumpActualDelta: UInt64?,
        at date: Date
    ) {
        receivedInputBuffers += 1
        receivedInputSampleFrames += sampleFrameCount
        inputFrameCountDistribution[sampleFrameCount, default: 0] += 1
        if overwrittenSampleFrameCount > 0 {
            overwrittenInputBuffers += 1
            overwrittenInputSampleFrames += overwrittenSampleFrameCount
        }
        if let qpcJumpActualDelta {
            qpcJumps += 1
            maximumQpcDelta = max(maximumQpcDelta ?? 0, qpcJumpActualDelta)
        }
        if let previousArrival {
            let gap = max(0, date.timeIntervalSince(previousArrival))
            maximumArrivalGapMilliseconds = max(
                maximumArrivalGapMilliseconds,
                Int((gap * 1_000).rounded())
            )
        }
        previousArrival = date
    }

    public mutating func recordReblocked(
        outputSampleFrameCount: Int,
        startQPCPosition: UInt64,
        endQPCPosition: UInt64,
        sourceSpanCount: Int
    ) {
        reblockedOutputBuffers += 1
        reblockedOutputSampleFrames += outputSampleFrameCount
        outputSourceSpanCount += sourceSpanCount
        if firstOutputStartQPCPosition == nil {
            firstOutputStartQPCPosition = startQPCPosition
        }
        lastOutputEndQPCPosition = endQPCPosition
    }

    public mutating func recordScheduled(outputSampleFrameCount: Int) {
        scheduledOutputBuffers += 1
        scheduledOutputSampleFrames += outputSampleFrameCount
    }

    public mutating func recordCompleted(outputSampleFrameCount: Int) {
        completedOutputBuffers += 1
        completedOutputSampleFrames += outputSampleFrameCount
    }

    public mutating func updateCarry(sampleFrameCount: Int) {
        carrySampleFrames = sampleFrameCount
    }

    public mutating func recordJitterBuffer(
        configuredLatencyMilliseconds: Int,
        effectiveTargetSampleFrames: Int?,
        queuedOutputBuffers: Int,
        queuedOutputSampleFrames: Int,
        scheduledPendingSampleFrames: Int,
        trimmedOutputBuffersDelta: Int,
        trimmedOutputSampleFramesDelta: Int,
        underrunCountDelta: Int,
        rebufferCountDelta: Int,
        rebufferDurationMillisecondsDelta: Int,
        maximumQueuedSampleFrames: Int
    ) {
        self.configuredLatencyMilliseconds = configuredLatencyMilliseconds
        self.effectiveTargetSampleFrames = effectiveTargetSampleFrames
        self.queuedOutputBuffers = queuedOutputBuffers
        self.queuedOutputSampleFrames = queuedOutputSampleFrames
        self.scheduledPendingSampleFrames = scheduledPendingSampleFrames
        trimmedOutputBuffers += trimmedOutputBuffersDelta
        trimmedOutputSampleFrames += trimmedOutputSampleFramesDelta
        underrunCount += underrunCountDelta
        rebufferCount += rebufferCountDelta
        rebufferDurationMilliseconds += rebufferDurationMillisecondsDelta
        self.maximumQueuedSampleFrames = max(
            self.maximumQueuedSampleFrames,
            maximumQueuedSampleFrames
        )
    }

    public mutating func snapshotAndReset(windowEnd: Date) -> AudioPipelineEvidenceWindowSnapshot {
        let snapshot = AudioPipelineEvidenceWindowSnapshot(
            start: windowStart,
            end: windowEnd,
            receivedInputBuffers: receivedInputBuffers,
            receivedInputSampleFrames: receivedInputSampleFrames,
            overwrittenInputBuffers: overwrittenInputBuffers,
            overwrittenInputSampleFrames: overwrittenInputSampleFrames,
            reblockedOutputBuffers: reblockedOutputBuffers,
            reblockedOutputSampleFrames: reblockedOutputSampleFrames,
            scheduledOutputBuffers: scheduledOutputBuffers,
            scheduledOutputSampleFrames: scheduledOutputSampleFrames,
            completedOutputBuffers: completedOutputBuffers,
            completedOutputSampleFrames: completedOutputSampleFrames,
            carrySampleFrames: carrySampleFrames,
            inputFrameCountDistribution: inputFrameCountDistribution,
            qpcJumps: qpcJumps,
            maximumQpcDelta: maximumQpcDelta,
            maximumArrivalGapMilliseconds: maximumArrivalGapMilliseconds,
            outputSourceSpanCount: outputSourceSpanCount,
            firstOutputStartQPCPosition: firstOutputStartQPCPosition,
            lastOutputEndQPCPosition: lastOutputEndQPCPosition,
            configuredLatencyMilliseconds: configuredLatencyMilliseconds,
            effectiveTargetSampleFrames: effectiveTargetSampleFrames,
            queuedOutputBuffers: queuedOutputBuffers,
            queuedOutputSampleFrames: queuedOutputSampleFrames,
            scheduledPendingSampleFrames: scheduledPendingSampleFrames,
            trimmedOutputBuffers: trimmedOutputBuffers,
            trimmedOutputSampleFrames: trimmedOutputSampleFrames,
            underrunCount: underrunCount,
            rebufferCount: rebufferCount,
            rebufferDurationMilliseconds: rebufferDurationMilliseconds,
            maximumQueuedSampleFrames: maximumQueuedSampleFrames
        )

        windowStart = windowEnd
        receivedInputBuffers = 0
        receivedInputSampleFrames = 0
        overwrittenInputBuffers = 0
        overwrittenInputSampleFrames = 0
        reblockedOutputBuffers = 0
        reblockedOutputSampleFrames = 0
        scheduledOutputBuffers = 0
        scheduledOutputSampleFrames = 0
        completedOutputBuffers = 0
        completedOutputSampleFrames = 0
        inputFrameCountDistribution.removeAll(keepingCapacity: true)
        qpcJumps = 0
        maximumQpcDelta = nil
        maximumArrivalGapMilliseconds = 0
        outputSourceSpanCount = 0
        firstOutputStartQPCPosition = nil
        lastOutputEndQPCPosition = nil
        trimmedOutputBuffers = 0
        trimmedOutputSampleFrames = 0
        underrunCount = 0
        rebufferCount = 0
        rebufferDurationMilliseconds = 0
        maximumQueuedSampleFrames = 0
        return snapshot
    }
}

public struct AudioArrivalBatch: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let receivedFrames: Int
    public let droppedFrames: Int
}

public struct AudioArrivalBatchTracker: Sendable {
    private let minimumGap: TimeInterval
    private let burstInterval: TimeInterval
    private var previousArrival: Date?
    private var candidate: AudioArrivalBatch?
    private var activeBatch: AudioArrivalBatch?

    public init(
        minimumGap: TimeInterval = 0.050,
        burstInterval: TimeInterval = 0.002
    ) {
        self.minimumGap = minimumGap
        self.burstInterval = burstInterval
    }

    public mutating func record(
        at date: Date,
        expectedInterval: TimeInterval,
        dropped: Bool
    ) -> AudioArrivalBatch? {
        defer { previousArrival = date }
        guard let previousArrival else {
            return nil
        }

        let interval = max(0, date.timeIntervalSince(previousArrival))
        if var activeBatch {
            if interval <= burstInterval {
                activeBatch = AudioArrivalBatch(
                    start: activeBatch.start,
                    end: date,
                    receivedFrames: activeBatch.receivedFrames + 1,
                    droppedFrames: activeBatch.droppedFrames + (dropped ? 1 : 0)
                )
                self.activeBatch = activeBatch
                return nil
            }

            self.activeBatch = nil
            candidate = batchCandidateIfNeeded(
                at: date,
                interval: interval,
                expectedInterval: expectedInterval,
                dropped: dropped
            )
            return activeBatch
        }

        if let candidate {
            if interval <= burstInterval {
                activeBatch = AudioArrivalBatch(
                    start: candidate.start,
                    end: date,
                    receivedFrames: candidate.receivedFrames + 1,
                    droppedFrames: candidate.droppedFrames + (dropped ? 1 : 0)
                )
                self.candidate = nil
                return nil
            }
            self.candidate = nil
        }

        candidate = batchCandidateIfNeeded(
            at: date,
            interval: interval,
            expectedInterval: expectedInterval,
            dropped: dropped
        )
        return nil
    }

    public mutating func finish() -> AudioArrivalBatch? {
        defer {
            candidate = nil
            activeBatch = nil
        }
        return activeBatch
    }

    private func batchCandidateIfNeeded(
        at date: Date,
        interval: TimeInterval,
        expectedInterval: TimeInterval,
        dropped: Bool
    ) -> AudioArrivalBatch? {
        let gapThreshold = max(minimumGap, expectedInterval * 3)
        guard interval >= gapThreshold else {
            return nil
        }
        return AudioArrivalBatch(
            start: date,
            end: date,
            receivedFrames: 1,
            droppedFrames: dropped ? 1 : 0
        )
    }
}
