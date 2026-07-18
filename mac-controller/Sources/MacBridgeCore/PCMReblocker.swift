import AVFoundation
import Foundation

public struct PCMInputBlock {
    public let sampleRate: Int
    public let qpcPosition: UInt64
    public let channels: [[Float]]

    public init(sampleRate: Int, qpcPosition: UInt64, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.qpcPosition = qpcPosition
        self.channels = channels
    }

    public var sampleFrameCount: Int {
        channels.first?.count ?? 0
    }
}

public struct PCMSourceSpan: Equatable, Sendable {
    public let qpcPosition: UInt64
    public let sourceFrameOffset: Int
    public let sampleFrameCount: Int

    public init(qpcPosition: UInt64, sourceFrameOffset: Int, sampleFrameCount: Int) {
        self.qpcPosition = qpcPosition
        self.sourceFrameOffset = sourceFrameOffset
        self.sampleFrameCount = sampleFrameCount
    }
}

public struct ReblockedPCMOutput {
    public let buffer: AVAudioPCMBuffer
    public let startQPCPosition: UInt64
    public let sourceSpans: [PCMSourceSpan]
}

public enum PCMReblockerError: Error, CustomStringConvertible, Equatable {
    case invalidSampleRate(Int)
    case missingChannels
    case inconsistentChannelLengths
    case emptyInput
    case formatCreationFailed
    case bufferCreationFailed

    public var description: String {
        switch self {
        case .invalidSampleRate(let sampleRate):
            return "PCM sample rate must be positive, got \(sampleRate)"
        case .missingChannels:
            return "PCM input must contain at least one channel"
        case .inconsistentChannelLengths:
            return "PCM input channels must contain equal sample-frame counts"
        case .emptyInput:
            return "PCM input must contain at least one sample frame"
        case .formatCreationFailed:
            return "failed to create non-interleaved float PCM format"
        case .bufferCreationFailed:
            return "failed to create fixed-size PCM output buffer"
        }
    }
}

public final class PCMReblocker: @unchecked Sendable {
    public static let outputFrameCount = 512

    private let lock = NSLock()
    private var sampleRate: Int?
    private var channelCount: Int?
    private var carryChannels: [[Float]] = []
    private var sourceSpans: [PCMSourceSpan] = []
    private var stopped = false

    public init() {}

    public var carrySampleFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return carryChannels.first?.count ?? 0
    }

    public func append(_ input: PCMInputBlock) throws -> [ReblockedPCMOutput] {
        try validate(input)

        lock.lock()
        defer { lock.unlock() }

        guard !stopped else {
            return []
        }

        let incomingChannelCount = input.channels.count
        if sampleRate != input.sampleRate || channelCount != incomingChannelCount {
            clearLocked()
            sampleRate = input.sampleRate
            channelCount = incomingChannelCount
            carryChannels = Array(repeating: [], count: incomingChannelCount)
        }

        for channelIndex in 0..<incomingChannelCount {
            carryChannels[channelIndex].append(contentsOf: input.channels[channelIndex])
        }
        sourceSpans.append(
            PCMSourceSpan(
                qpcPosition: input.qpcPosition,
                sourceFrameOffset: 0,
                sampleFrameCount: input.sampleFrameCount
            )
        )

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(input.sampleRate),
            channels: AVAudioChannelCount(incomingChannelCount),
            interleaved: false
        ) else {
            throw PCMReblockerError.formatCreationFailed
        }

        var outputs: [ReblockedPCMOutput] = []
        while (carryChannels.first?.count ?? 0) >= Self.outputFrameCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Self.outputFrameCount)
            ), let outputChannels = buffer.floatChannelData else {
                throw PCMReblockerError.bufferCreationFailed
            }

            buffer.frameLength = AVAudioFrameCount(Self.outputFrameCount)
            for channelIndex in 0..<incomingChannelCount {
                carryChannels[channelIndex].withUnsafeBufferPointer { source in
                    outputChannels[channelIndex].update(
                        from: source.baseAddress!,
                        count: Self.outputFrameCount
                    )
                }
            }

            let outputSpans = consumeSourceSpansLocked(sampleFrameCount: Self.outputFrameCount)
            let startQPCPosition = qpcPosition(
                for: outputSpans[0],
                sampleRate: input.sampleRate
            )
            outputs.append(
                ReblockedPCMOutput(
                    buffer: buffer,
                    startQPCPosition: startQPCPosition,
                    sourceSpans: outputSpans
                )
            )

            for channelIndex in 0..<incomingChannelCount {
                carryChannels[channelIndex].removeFirst(Self.outputFrameCount)
            }
        }
        return outputs
    }

    public func stop() {
        lock.lock()
        stopped = true
        clearLocked()
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        clearLocked()
        sampleRate = nil
        channelCount = nil
        lock.unlock()
    }

    private func validate(_ input: PCMInputBlock) throws {
        guard input.sampleRate > 0 else {
            throw PCMReblockerError.invalidSampleRate(input.sampleRate)
        }
        guard !input.channels.isEmpty else {
            throw PCMReblockerError.missingChannels
        }
        guard input.sampleFrameCount > 0 else {
            throw PCMReblockerError.emptyInput
        }
        guard input.channels.allSatisfy({ $0.count == input.sampleFrameCount }) else {
            throw PCMReblockerError.inconsistentChannelLengths
        }
    }

    private func consumeSourceSpansLocked(sampleFrameCount: Int) -> [PCMSourceSpan] {
        var remaining = sampleFrameCount
        var consumed: [PCMSourceSpan] = []

        while remaining > 0 {
            let span = sourceSpans[0]
            let count = min(remaining, span.sampleFrameCount)
            consumed.append(
                PCMSourceSpan(
                    qpcPosition: span.qpcPosition,
                    sourceFrameOffset: span.sourceFrameOffset,
                    sampleFrameCount: count
                )
            )
            remaining -= count

            if count == span.sampleFrameCount {
                sourceSpans.removeFirst()
            } else {
                sourceSpans[0] = PCMSourceSpan(
                    qpcPosition: span.qpcPosition,
                    sourceFrameOffset: span.sourceFrameOffset + count,
                    sampleFrameCount: span.sampleFrameCount - count
                )
            }
        }
        return consumed
    }

    private func qpcPosition(for span: PCMSourceSpan, sampleRate: Int) -> UInt64 {
        let offset = Double(span.sourceFrameOffset) * 10_000_000 / Double(sampleRate)
        return span.qpcPosition + UInt64(offset.rounded())
    }

    private func clearLocked() {
        carryChannels.removeAll(keepingCapacity: false)
        sourceSpans.removeAll(keepingCapacity: false)
    }
}
