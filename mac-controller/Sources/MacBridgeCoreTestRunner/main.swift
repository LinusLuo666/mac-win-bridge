import AVFoundation
import Foundation
import MacBridgeCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class ThreadSafeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ScriptedInputStream: InputStream {
    enum Step {
        case bytes([UInt8])
        case zero(Stream.Status, Error? = nil)
    }

    private var steps: [Step]
    private var reportedStatus: Stream.Status = .open
    private var reportedError: Error?

    init(steps: [Step]) {
        self.steps = steps
        super.init(data: Data())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var streamStatus: Stream.Status {
        reportedStatus
    }

    override var streamError: Error? {
        reportedError
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard !steps.isEmpty else {
            reportedStatus = .atEnd
            return 0
        }

        switch steps.removeFirst() {
        case .bytes(let bytes):
            reportedStatus = .open
            reportedError = nil
            let count = min(bytes.count, len)
            for index in 0..<count {
                buffer[index] = bytes[index]
            }
            return count
        case .zero(let status, let error):
            reportedStatus = status
            reportedError = error
            return 0
        }
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

func expectNil<T>(_ actual: T?, _ message: String) throws {
    if let actual {
        throw TestFailure(description: "\(message): expected nil, got \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ message: String) throws {
    if !actual {
        throw TestFailure(description: "\(message): expected true")
    }
}

func expectFalse(_ actual: Bool, _ message: String) throws {
    if actual {
        throw TestFailure(description: "\(message): expected false")
    }
}

func pcmSamples(_ buffer: AVAudioPCMBuffer, channel: Int) throws -> [Float] {
    guard let channelData = buffer.floatChannelData else {
        throw TestFailure(description: "PCM buffer has no float channel data")
    }
    return Array(
        UnsafeBufferPointer(
            start: channelData[channel],
            count: Int(buffer.frameLength)
        )
    )
}

func reblockedOutput(
    qpcPosition: UInt64,
    sampleRate: Int = 48_000,
    channels: Int = 2
) throws -> ReblockedPCMOutput {
    let reblocker = PCMReblocker()
    let samples = Array(
        repeating: [Float](repeating: Float(qpcPosition), count: PCMReblocker.outputFrameCount),
        count: channels
    )
    let outputs = try reblocker.append(
        PCMInputBlock(
            sampleRate: sampleRate,
            qpcPosition: qpcPosition,
            channels: samples
        )
    )
    guard let output = outputs.first else {
        throw TestFailure(description: "expected one reblocked output")
    }
    return output
}

func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    for shift in stride(from: 0, through: 24, by: 8) {
        data.append(UInt8((value >> UInt32(shift)) & 0xFF))
    }
}

func appendUInt64LE(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 0, through: 56, by: 8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
}

func run(_ name: String, _ test: () throws -> Void) -> Bool {
    do {
        try test()
        print("PASS \(name)")
        return true
    } catch {
        print("FAIL \(name): \(error)")
        return false
    }
}

let tests: [(String, () throws -> Void)] = [
    ("KeyboardEventKind raw values", {
        try expectEqual(KeyboardEventKind.down.rawValue, "down", "down raw value")
        try expectEqual(KeyboardEventKind.up.rawValue, "up", "up raw value")
        try expectEqual(KeyboardEventKind.flagsChanged.rawValue, "flagsChanged", "flagsChanged raw value")
    }),
    ("KeyboardMessage encodes one JSON line", {
        let message = KeyboardMessage(
            event: .down,
            key: "KeyA",
            modifiers: [.shift],
            sequence: 42
        )

        let line = try message.jsonLine()

        try expectEqual(
            line,
            #"{"type":"key","event":"down","key":"KeyA","modifiers":["shift"],"sequence":42}"# + "\n",
            "encoded key down message"
        )
    }),
    ("KeyboardMessage encodes empty modifiers", {
        let message = KeyboardMessage(
            event: .up,
            key: "Enter",
            modifiers: [],
            sequence: 7
        )

        let line = try message.jsonLine()

        try expectEqual(
            line,
            #"{"type":"key","event":"up","key":"Enter","modifiers":[],"sequence":7}"# + "\n",
            "encoded key up message"
        )
    }),
    ("AudioControlMessage encodes enable command", {
        let message = AudioControlMessage(
            enabled: true,
            mode: .stable,
            volume: 0.5,
            muted: false
        )

        let line = try message.jsonLine()

        try expectEqual(
            line,
            #"{"type":"audioControl","enabled":true,"mode":"stable","volume":0.5,"muted":false}"# + "\n",
            "encoded audio enable message"
        )
    }),
    ("AudioControlMessage clamps volume", {
        let message = AudioControlMessage(
            enabled: true,
            mode: .lowLatency,
            volume: 2.0,
            muted: false
        )

        try expectEqual(message.volume, 1.0, "clamped volume")
    }),
    ("Windows audio frame parses extensible float metadata", {
        var payload = Data()
        appendUInt32LE(48_000, to: &payload)
        appendUInt16LE(2, to: &payload)
        appendUInt16LE(32, to: &payload)
        appendUInt16LE(0xFFFE, to: &payload)
        appendUInt16LE(8, to: &payload)
        appendUInt32LE(2, to: &payload)
        appendUInt64LE(123_456, to: &payload)
        payload.append(Data(repeating: 0, count: 16))

        var header = Data([WindowsAudioFrameProtocol.messageType])
        appendUInt32LE(UInt32(payload.count), to: &header)

        try expectEqual(
            try WindowsAudioFrameProtocol.payloadLength(from: header),
            payload.count,
            "payload length"
        )
        let frame = try WindowsAudioFrameProtocol.parse(payload: payload)
        try expectEqual(frame.metadata.sampleRate, 48_000, "sample rate")
        try expectEqual(frame.metadata.channels, 2, "channels")
        try expectEqual(frame.metadata.bitsPerSample, 32, "bits per sample")
        try expectEqual(frame.metadata.formatTag, 0xFFFE, "format tag")
        try expectEqual(frame.metadata.blockAlign, 8, "block align")
        try expectEqual(frame.metadata.frameCount, 2, "frame count")
        try expectEqual(frame.metadata.qpcPosition, 123_456, "QPC position")
        try expectEqual(frame.metadata.encoding, .float32, "extensible encoding")
        try expectEqual(frame.pcm.count, 16, "PCM bytes")
    }),
    ("ExactByteReader joins short TCP reads", {
        let source = Array(0..<20).map(UInt8.init)
        var sourceOffset = 0
        let result = try ExactByteReader.read(byteCount: source.count) { pointer, maximumLength in
            let count = min(3, maximumLength, source.count - sourceOffset)
            guard count > 0 else { return 0 }
            for index in 0..<count {
                pointer[index] = source[sourceOffset + index]
            }
            sourceOffset += count
            return count
        }
        try expectEqual(result, Data(source), "joined bytes")
    }),
    ("ExactByteReader retries a zero-byte read while InputStream remains open", {
        let stream = ScriptedInputStream(steps: [
            .zero(.open),
            .bytes([1, 2, 3])
        ])
        var observedStatuses: [Stream.Status] = []

        let result = try ExactByteReader.read(
            byteCount: 3,
            from: stream,
            retryDelay: 0,
            onZeroRead: { status, _, _ in
                observedStatuses.append(status)
            }
        )

        try expectEqual(result, Data([1, 2, 3]), "bytes after temporary zero read")
        try expectEqual(observedStatuses, [.open], "observed temporary stream status")
    }),
    ("ExactByteReader treats zero bytes at InputStream end as EOF", {
        let stream = ScriptedInputStream(steps: [.zero(.atEnd)])

        let result = try ExactByteReader.read(
            byteCount: 3,
            from: stream,
            retryDelay: 0
        )

        try expectNil(result, "at-end read result")
    }),
    ("ExactByteReader reports truncated data when InputStream ends after partial bytes", {
        let stream = ScriptedInputStream(steps: [
            .bytes([1, 2]),
            .zero(.atEnd)
        ])

        do {
            _ = try ExactByteReader.read(
                byteCount: 3,
                from: stream,
                retryDelay: 0
            )
            throw TestFailure(description: "expected truncated stream error")
        } catch let error as ExactByteReaderError {
            try expectEqual(error, .truncated(expected: 3, actual: 2), "truncated stream error")
        }
    }),
    ("ExactByteReader throws InputStream error status", {
        let expectedError = NSError(domain: "ExactByteReaderTests", code: 91)
        let stream = ScriptedInputStream(steps: [.zero(.error, expectedError)])

        do {
            _ = try ExactByteReader.read(
                byteCount: 3,
                from: stream,
                retryDelay: 0
            )
            throw TestFailure(description: "expected InputStream error")
        } catch let error as NSError {
            try expectEqual(error.domain, expectedError.domain, "stream error domain")
            try expectEqual(error.code, expectedError.code, "stream error code")
        }
    }),
    ("AudioBufferQueueLimiter permits only one unplayed buffer", {
        let limiter = AudioBufferQueueLimiter(maximumPendingBuffers: 1)

        try expectTrue(limiter.tryReserve(), "first buffer should be accepted")
        try expectFalse(limiter.tryReserve(), "second buffer must wait for the first to play")
        limiter.release()
        try expectTrue(limiter.tryReserve(), "a completed buffer frees the only slot")
    }),
    ("AudioBufferQueueLimiter capacity two blocks a third buffer until release", {
        let limiter = AudioBufferQueueLimiter(maximumPendingBuffers: 2)
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let waiterResult = ThreadSafeBox(false)

        try expectTrue(limiter.tryReserve(), "first buffer should be accepted")
        try expectTrue(limiter.tryReserve(), "second buffer should be accepted")

        Thread {
            waiterStarted.signal()
            waiterResult.set(limiter.waitForSlot())
            waiterFinished.signal()
        }.start()

        try expectEqual(waiterStarted.wait(timeout: .now() + 1), .success, "third waiter started")
        try expectEqual(
            waiterFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "third buffer must wait while both slots are occupied"
        )

        limiter.release()
        try expectEqual(
            waiterFinished.wait(timeout: .now() + 1),
            .success,
            "releasing one buffer should admit the waiting buffer"
        )
        try expectTrue(waiterResult.get(), "third buffer reservation should succeed after release")
    }),
    ("AudioBufferQueueLimiter stop wakes a capacity two waiter", {
        let limiter = AudioBufferQueueLimiter(maximumPendingBuffers: 2)
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let waiterResult = ThreadSafeBox(true)

        try expectTrue(limiter.tryReserve(), "first buffer should be accepted")
        try expectTrue(limiter.tryReserve(), "second buffer should be accepted")

        Thread {
            waiterStarted.signal()
            waiterResult.set(limiter.waitForSlot())
            waiterFinished.signal()
        }.start()

        try expectEqual(waiterStarted.wait(timeout: .now() + 1), .success, "stop waiter started")
        limiter.stop()
        try expectEqual(
            waiterFinished.wait(timeout: .now() + 1),
            .success,
            "stop should wake the waiting thread"
        )
        try expectFalse(waiterResult.get(), "a waiter released by stop must not reserve a slot")
    }),
    ("PCMReblocker turns three 480-frame mono inputs into continuous 512-frame outputs", {
        let reblocker = PCMReblocker()
        let first = try reblocker.append(
            PCMInputBlock(
                sampleRate: 48_000,
                qpcPosition: 1_000_000,
                channels: [(0..<480).map(Float.init)]
            )
        )
        let second = try reblocker.append(
            PCMInputBlock(
                sampleRate: 48_000,
                qpcPosition: 1_100_000,
                channels: [(480..<960).map(Float.init)]
            )
        )
        let third = try reblocker.append(
            PCMInputBlock(
                sampleRate: 48_000,
                qpcPosition: 1_200_000,
                channels: [(960..<1_440).map(Float.init)]
            )
        )

        try expectEqual(first.count, 0, "first 480 frames must remain as carry")
        try expectEqual(second.count, 1, "960 input frames produce one 512-frame output")
        try expectEqual(third.count, 1, "the next 480 frames produce another output")
        try expectEqual(second[0].buffer.frameLength, 512, "first output frame length")
        try expectEqual(third[0].buffer.frameLength, 512, "second output frame length")
        try expectEqual(
            try pcmSamples(second[0].buffer, channel: 0) + pcmSamples(third[0].buffer, channel: 0),
            (0..<1_024).map(Float.init),
            "mono samples remain continuous"
        )
        try expectEqual(reblocker.carrySampleFrames, 416, "remaining mono carry")
        try expectEqual(second[0].startQPCPosition, 1_000_000, "first output start QPC")
        try expectEqual(
            second[0].sourceSpans,
            [
                PCMSourceSpan(qpcPosition: 1_000_000, sourceFrameOffset: 0, sampleFrameCount: 480),
                PCMSourceSpan(qpcPosition: 1_100_000, sourceFrameOffset: 0, sampleFrameCount: 32)
            ],
            "first output source spans"
        )
        try expectEqual(
            third[0].sourceSpans,
            [
                PCMSourceSpan(qpcPosition: 1_100_000, sourceFrameOffset: 32, sampleFrameCount: 448),
                PCMSourceSpan(qpcPosition: 1_200_000, sourceFrameOffset: 0, sampleFrameCount: 64)
            ],
            "second output source spans"
        )
    }),
    ("PCMReblocker preserves independent stereo channel order", {
        let reblocker = PCMReblocker()
        let left = (0..<960).map(Float.init)
        let right = (0..<960).map { Float($0) + 10_000 }

        _ = try reblocker.append(
            PCMInputBlock(
                sampleRate: 48_000,
                qpcPosition: 2_000_000,
                channels: [Array(left[0..<480]), Array(right[0..<480])]
            )
        )
        let outputs = try reblocker.append(
            PCMInputBlock(
                sampleRate: 48_000,
                qpcPosition: 2_100_000,
                channels: [Array(left[480..<960]), Array(right[480..<960])]
            )
        )

        try expectEqual(outputs.count, 1, "stereo output count")
        try expectEqual(try pcmSamples(outputs[0].buffer, channel: 0), Array(left[0..<512]), "left channel")
        try expectEqual(try pcmSamples(outputs[0].buffer, channel: 1), Array(right[0..<512]), "right channel")
    }),
    ("PCMReblocker conserves sample frames over a long input sequence", {
        let reblocker = PCMReblocker()
        var outputSampleFrames = 0

        for inputIndex in 0..<100 {
            let start = inputIndex * 480
            let outputs = try reblocker.append(
                PCMInputBlock(
                    sampleRate: 48_000,
                    qpcPosition: UInt64(3_000_000 + inputIndex * 100_000),
                    channels: [(start..<(start + 480)).map(Float.init)]
                )
            )
            outputSampleFrames += outputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
        }

        try expectEqual(
            outputSampleFrames + reblocker.carrySampleFrames,
            48_000,
            "output plus carry must equal all input sample frames"
        )
    }),
    ("PCMReblocker stop discards partial carry", {
        let reblocker = PCMReblocker()
        _ = try reblocker.append(
            PCMInputBlock(
                sampleRate: 48_000,
                qpcPosition: 4_000_000,
                channels: [(0..<480).map(Float.init)]
            )
        )
        try expectEqual(reblocker.carrySampleFrames, 480, "carry before stop")

        reblocker.stop()

        try expectEqual(reblocker.carrySampleFrames, 0, "stop clears carry")
    }),
    ("Audio latency setting validates whole milliseconds in range", {
        try expectEqual(AudioLatencySetting.defaultMilliseconds, 50, "default latency")
        try expectEqual(AudioLatencySetting.parse("10"), 10, "minimum latency")
        try expectEqual(AudioLatencySetting.parse("50"), 50, "balanced latency")
        try expectEqual(AudioLatencySetting.parse("120"), 120, "maximum latency")
        try expectNil(AudioLatencySetting.parse("9"), "below minimum")
        try expectNil(AudioLatencySetting.parse("121"), "above maximum")
        try expectNil(AudioLatencySetting.parse("50.5"), "fractional milliseconds")
        try expectNil(AudioLatencySetting.parse("abc"), "non-numeric latency")
    }),
    ("PCM jitter buffer rounds latency thresholds to 512-frame blocks", {
        let low = PCMOutputJitterBuffer.thresholds(
            sampleRate: 48_000,
            requestedLatencyMilliseconds: 10
        )
        let balanced = PCMOutputJitterBuffer.thresholds(
            sampleRate: 48_000,
            requestedLatencyMilliseconds: 50
        )
        let stable = PCMOutputJitterBuffer.thresholds(
            sampleRate: 48_000,
            requestedLatencyMilliseconds: 120
        )

        try expectEqual(low.targetSampleFrames, 512, "10 ms target")
        try expectEqual(low.maximumSampleFrames, 1_536, "10 ms maximum")
        try expectEqual(balanced.targetSampleFrames, 2_560, "50 ms target")
        try expectEqual(balanced.maximumSampleFrames, 3_584, "50 ms maximum")
        try expectEqual(stable.targetSampleFrames, 6_144, "120 ms target")
        try expectEqual(stable.maximumSampleFrames, 7_168, "120 ms maximum")
    }),
    ("PCM jitter buffer primes before returning oldest source block", {
        let buffer = PCMOutputJitterBuffer(requestedLatencyMilliseconds: 50)
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let scheduledQPC = ThreadSafeBox<UInt64?>(nil)

        Thread {
            waiterStarted.signal()
            scheduledQPC.set(buffer.waitForNextToSchedule()?.startQPCPosition)
            waiterFinished.signal()
        }.start()

        try expectEqual(waiterStarted.wait(timeout: .now() + 1), .success, "waiter started")
        _ = buffer.enqueue(try (0..<4).map { try reblockedOutput(qpcPosition: UInt64($0 + 1)) })
        try expectEqual(
            waiterFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "four blocks remain below the 50 ms target"
        )

        _ = buffer.enqueue([try reblockedOutput(qpcPosition: 5)])
        try expectEqual(waiterFinished.wait(timeout: .now() + 1), .success, "target wakes waiter")
        try expectEqual(scheduledQPC.get(), 1, "oldest QPC is scheduled first")

        let snapshot = buffer.snapshot()
        try expectEqual(snapshot.state, .playing, "state after priming")
        try expectEqual(snapshot.queuedOutputSampleFrames, 2_048, "four blocks remain queued")
        try expectEqual(snapshot.scheduledPendingSampleFrames, 512, "one block is pending")
        buffer.stop()
    }),
    ("PCM jitter buffer preserves bounded bursts and trims oldest overflow", {
        let buffer = PCMOutputJitterBuffer(requestedLatencyMilliseconds: 50)
        let firstFive = try (0..<5).map { try reblockedOutput(qpcPosition: UInt64($0 + 1)) }
        let withinMargin = try (5..<7).map { try reblockedOutput(qpcPosition: UInt64($0 + 1)) }

        let initial = buffer.enqueue(firstFive)
        let bounded = buffer.enqueue(withinMargin)
        let overflow = buffer.enqueue([try reblockedOutput(qpcPosition: 8)])

        try expectEqual(initial.trimmedOutputBuffers, 0, "target fill is retained")
        try expectEqual(bounded.trimmedOutputBuffers, 0, "burst inside margin is retained")
        try expectEqual(overflow.trimmedOutputBuffers, 3, "overflow trims back to target")
        try expectEqual(overflow.trimmedOutputSampleFrames, 1_536, "trimmed sample frames")
        try expectEqual(buffer.snapshot().queuedOutputSampleFrames, 2_560, "queue returns to target")
        try expectEqual(
            buffer.waitForNextToSchedule()?.startQPCPosition,
            4,
            "oldest retained block follows the trimmed blocks"
        )
        buffer.stop()
    }),
    ("PCM jitter buffer re-primes after underrun and records duration", {
        let buffer = PCMOutputJitterBuffer(requestedLatencyMilliseconds: 10)
        _ = buffer.enqueue(
            [try reblockedOutput(qpcPosition: 10)],
            at: Date(timeIntervalSince1970: 1)
        )
        let scheduled = buffer.waitForNextToSchedule()
        try expectEqual(scheduled?.startQPCPosition, 10, "scheduled block")

        buffer.completeScheduled(
            sampleFrames: PCMReblocker.outputFrameCount,
            at: Date(timeIntervalSince1970: 2)
        )
        try expectEqual(buffer.snapshot().state, .priming, "empty playback re-primes")

        _ = buffer.enqueue(
            [try reblockedOutput(qpcPosition: 20)],
            at: Date(timeIntervalSince1970: 3)
        )
        let snapshot = buffer.snapshot()
        try expectEqual(snapshot.state, .playing, "target resumes playback")
        try expectEqual(snapshot.underrunCount, 1, "underrun count")
        try expectEqual(snapshot.rebufferCount, 1, "rebuffer count")
        try expectEqual(snapshot.totalRebufferDurationMilliseconds, 1_000, "rebuffer duration")
        buffer.stop()
    }),
    ("PCM jitter buffer conserves queued and trimmed sample frames", {
        let buffer = PCMOutputJitterBuffer(requestedLatencyMilliseconds: 50)
        for qpc in 1...20 {
            _ = buffer.enqueue([try reblockedOutput(qpcPosition: UInt64(qpc))])
        }
        let snapshot = buffer.snapshot()
        try expectEqual(
            snapshot.queuedOutputSampleFrames + snapshot.trimmedOutputSampleFrames,
            20 * PCMReblocker.outputFrameCount,
            "queued plus trimmed equals all input output frames"
        )
        buffer.stop()
    }),
    ("PCM jitter buffer stop wakes a priming waiter", {
        let buffer = PCMOutputJitterBuffer(requestedLatencyMilliseconds: 50)
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let waiterResult = ThreadSafeBox<ReblockedPCMOutput?>(nil)

        Thread {
            waiterStarted.signal()
            waiterResult.set(buffer.waitForNextToSchedule())
            waiterFinished.signal()
        }.start()

        try expectEqual(waiterStarted.wait(timeout: .now() + 1), .success, "waiter started")
        buffer.stop()
        try expectEqual(waiterFinished.wait(timeout: .now() + 1), .success, "stop wakes waiter")
        try expectNil(waiterResult.get(), "stopped waiter result")
    }),
    ("LatestFrameBuffer keeps only the newest frame", {
        let buffer = LatestFrameBuffer<String>()

        try expectEqual(buffer.put("A"), .stored, "A result")
        try expectEqual(buffer.put("B"), .replaced, "B replaces A")
        try expectEqual(buffer.put("C"), .replaced, "C replaces B")
        try expectEqual(buffer.waitForLatest(), "C", "newest frame")
    }),
    ("LatestFrameBuffer reports the exact replaced element", {
        let buffer = LatestFrameBuffer<String>()

        let first = buffer.putReturningReplaced("A")
        let second = buffer.putReturningReplaced("B")

        try expectEqual(first.result, .stored, "first insertion result")
        try expectNil(first.replaced, "first insertion replaced value")
        try expectEqual(second.result, .replaced, "second insertion result")
        try expectEqual(second.replaced, "A", "exact replaced value")
        try expectEqual(buffer.waitForLatest(), "B", "latest value remains capacity one")
    }),
    ("LatestFrameBuffer stop wakes an empty waiter", {
        let buffer = LatestFrameBuffer<String>()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = ThreadSafeBox<String?>(nil)

        Thread {
            started.signal()
            result.set(buffer.waitForLatest())
            finished.signal()
        }.start()

        try expectEqual(started.wait(timeout: .now() + 1), .success, "waiter started")
        buffer.stop()
        try expectEqual(finished.wait(timeout: .now() + 1), .success, "waiter finished")
        try expectNil(result.get(), "stopped wait result")
    }),
    ("AudioQPCJumpTracker accepts contiguous packets", {
        var tracker = AudioQPCJumpTracker()

        try expectNil(
            tracker.record(position: 1_000_000, frameCount: 480, sampleRate: 48_000),
            "first frame"
        )
        try expectNil(
            tracker.record(position: 1_100_000, frameCount: 480, sampleRate: 48_000),
            "contiguous frame"
        )
    }),
    ("AudioQPCJumpTracker reports skipped playback time", {
        var tracker = AudioQPCJumpTracker()

        _ = tracker.record(position: 1_000_000, frameCount: 480, sampleRate: 48_000)
        let jump = tracker.record(position: 1_400_000, frameCount: 480, sampleRate: 48_000)

        try expectEqual(jump?.actualDelta, 400_000, "actual QPC delta")
        try expectEqual(jump?.expectedDelta, 100_000, "expected QPC delta")
    }),
    ("Audio evidence windows align to five-second wall clock boundaries", {
        let window = AudioEvidenceClock.alignedWindow(
            containing: Date(timeIntervalSince1970: 12.345),
            duration: 5
        )

        try expectEqual(window.start, Date(timeIntervalSince1970: 10), "aligned window start")
        try expectEqual(window.end, Date(timeIntervalSince1970: 15), "aligned window end")
    }),
    ("Audio evidence window reports deltas and frame distribution", {
        var tracker = AudioEvidenceWindowTracker(
            windowStart: Date(timeIntervalSince1970: 10)
        )
        tracker.recordReceived(
            frameCount: 480,
            dropped: false,
            at: Date(timeIntervalSince1970: 10.1)
        )
        tracker.recordReceived(
            frameCount: 960,
            dropped: true,
            at: Date(timeIntervalSince1970: 10.4)
        )
        tracker.recordScheduled(qpcJumpActualDelta: nil)
        tracker.recordScheduled(qpcJumpActualDelta: 400_000)
        tracker.recordCompleted()
        tracker.recordCompleted()

        let snapshot = tracker.snapshotAndReset(
            windowEnd: Date(timeIntervalSince1970: 15)
        )

        try expectEqual(snapshot.receivedFrames, 2, "received delta")
        try expectEqual(snapshot.scheduledFrames, 2, "scheduled delta")
        try expectEqual(snapshot.completedFrames, 2, "completion delta")
        try expectEqual(snapshot.droppedFrames, 1, "dropped delta")
        try expectEqual(snapshot.frameCountDistribution, [480: 1, 960: 1], "frame count distribution")
        try expectEqual(snapshot.qpcJumps, 1, "QPC jump delta")
        try expectEqual(snapshot.maximumQpcDelta, 400_000, "maximum QPC delta")
        try expectEqual(snapshot.maximumArrivalGapMilliseconds, 300, "maximum arrival gap")

        tracker.recordReceived(
            frameCount: 480,
            dropped: false,
            at: Date(timeIntervalSince1970: 15.1)
        )
        let nextSnapshot = tracker.snapshotAndReset(
            windowEnd: Date(timeIntervalSince1970: 20)
        )
        try expectEqual(nextSnapshot.start, Date(timeIntervalSince1970: 15), "next window start")
        try expectEqual(nextSnapshot.receivedFrames, 1, "next received delta")
        try expectEqual(nextSnapshot.frameCountDistribution, [480: 1], "next frame distribution")
    }),
    ("Audio pipeline evidence tracks buffers and sample-frame conservation", {
        var tracker = AudioPipelineEvidenceWindowTracker(
            windowStart: Date(timeIntervalSince1970: 20)
        )
        tracker.recordInput(
            sampleFrameCount: 480,
            overwrittenSampleFrameCount: 0,
            qpcJumpActualDelta: nil,
            at: Date(timeIntervalSince1970: 20.01)
        )
        tracker.recordInput(
            sampleFrameCount: 480,
            overwrittenSampleFrameCount: 480,
            qpcJumpActualDelta: 200_000,
            at: Date(timeIntervalSince1970: 20.02)
        )
        tracker.recordReblocked(
            outputSampleFrameCount: 512,
            startQPCPosition: 10_000,
            endQPCPosition: 116_667,
            sourceSpanCount: 2
        )
        tracker.recordScheduled(outputSampleFrameCount: 512)
        tracker.recordCompleted(outputSampleFrameCount: 512)
        tracker.updateCarry(sampleFrameCount: 448)

        let snapshot = tracker.snapshotAndReset(
            windowEnd: Date(timeIntervalSince1970: 25)
        )

        try expectEqual(snapshot.receivedInputBuffers, 2, "received input buffers")
        try expectEqual(snapshot.receivedInputSampleFrames, 960, "received input sample frames")
        try expectEqual(snapshot.overwrittenInputBuffers, 1, "overwritten input buffers")
        try expectEqual(snapshot.overwrittenInputSampleFrames, 480, "overwritten input sample frames")
        try expectEqual(snapshot.reblockedOutputBuffers, 1, "reblocked output buffers")
        try expectEqual(snapshot.reblockedOutputSampleFrames, 512, "reblocked output sample frames")
        try expectEqual(snapshot.scheduledOutputBuffers, 1, "scheduled output buffers")
        try expectEqual(snapshot.scheduledOutputSampleFrames, 512, "scheduled output sample frames")
        try expectEqual(snapshot.completedOutputBuffers, 1, "completed output buffers")
        try expectEqual(snapshot.completedOutputSampleFrames, 512, "completed output sample frames")
        try expectEqual(snapshot.carrySampleFrames, 448, "carry sample frames")
        try expectEqual(snapshot.qpcJumps, 1, "raw input QPC jumps")
        try expectEqual(snapshot.maximumQpcDelta, 200_000, "raw input maximum QPC delta")
        try expectEqual(snapshot.outputSourceSpanCount, 2, "output source span count")
        try expectEqual(snapshot.firstOutputStartQPCPosition, 10_000, "first output QPC")
        try expectEqual(snapshot.lastOutputEndQPCPosition, 116_667, "last output QPC")
    }),
    ("Audio arrival batch reports exact burst boundaries", {
        var tracker = AudioArrivalBatchTracker()

        try expectNil(
            tracker.record(at: Date(timeIntervalSince1970: 0), expectedInterval: 0.01, dropped: false),
            "initial frame"
        )
        try expectNil(
            tracker.record(at: Date(timeIntervalSince1970: 1), expectedInterval: 0.01, dropped: true),
            "candidate after receive gap"
        )
        try expectNil(
            tracker.record(at: Date(timeIntervalSince1970: 1.001), expectedInterval: 0.01, dropped: true),
            "batch begins"
        )
        try expectNil(
            tracker.record(at: Date(timeIntervalSince1970: 1.0015), expectedInterval: 0.01, dropped: false),
            "batch continues"
        )
        let batch = tracker.record(
            at: Date(timeIntervalSince1970: 1.02),
            expectedInterval: 0.01,
            dropped: false
        )

        try expectEqual(batch?.start, Date(timeIntervalSince1970: 1), "batch start")
        try expectEqual(batch?.end, Date(timeIntervalSince1970: 1.0015), "batch end")
        try expectEqual(batch?.receivedFrames, 3, "batch frames")
        try expectEqual(batch?.droppedFrames, 2, "batch drops")
    }),
    ("ReconnectBackoff grows and caps delay", {
        var backoff = ReconnectBackoff(maximumDelay: 10)
        try expectEqual(backoff.nextDelay(), 1, "first delay")
        try expectEqual(backoff.nextDelay(), 2, "second delay")
        try expectEqual(backoff.nextDelay(), 4, "third delay")
        try expectEqual(backoff.nextDelay(), 8, "fourth delay")
        try expectEqual(backoff.nextDelay(), 10, "capped delay")
        try expectEqual(backoff.nextDelay(), 10, "remains capped")
        backoff.reset()
        try expectEqual(backoff.nextDelay(), 1, "reset delay")
    }),
    ("MacKeyMapper maps M0 keys", {
        try expectEqual(MacKeyMapper.stableKey(for: 0), "KeyA", "A key")
        try expectEqual(MacKeyMapper.stableKey(for: 11), "KeyB", "B key")
        try expectEqual(MacKeyMapper.stableKey(for: 18), "Digit1", "1 key")
        try expectEqual(MacKeyMapper.stableKey(for: 36), "Enter", "enter key")
        try expectEqual(MacKeyMapper.stableKey(for: 48), "Tab", "tab key")
        try expectEqual(MacKeyMapper.stableKey(for: 49), "Space", "space key")
        try expectEqual(MacKeyMapper.stableKey(for: 51), "Backspace", "backspace key")
        try expectEqual(MacKeyMapper.stableKey(for: 53), "Escape", "escape key")
        try expectEqual(MacKeyMapper.stableKey(for: 123), "ArrowLeft", "left arrow")
        try expectEqual(MacKeyMapper.stableKey(for: 124), "ArrowRight", "right arrow")
        try expectEqual(MacKeyMapper.stableKey(for: 125), "ArrowDown", "down arrow")
        try expectEqual(MacKeyMapper.stableKey(for: 126), "ArrowUp", "up arrow")
    }),
    ("MacKeyMapper returns nil for unsupported keys", {
        try expectNil(MacKeyMapper.stableKey(for: 999), "unsupported key")
    }),
    ("MacKeyMapper maps modifier keys for flagsChanged events", {
        try expectEqual(MacKeyMapper.stableKey(for: 55), "Command", "left command")
        try expectEqual(MacKeyMapper.stableKey(for: 56), "Shift", "left shift")
        try expectEqual(MacKeyMapper.stableKey(for: 58), "Option", "left option")
        try expectEqual(MacKeyMapper.stableKey(for: 59), "Control", "left control")
        try expectEqual(MacKeyMapper.stableKey(for: 60), "Shift", "right shift")
        try expectEqual(MacKeyMapper.stableKey(for: 61), "Option", "right option")
        try expectEqual(MacKeyMapper.stableKey(for: 62), "Control", "right control")
        try expectEqual(MacKeyMapper.stableKey(for: 63), "Fn", "function key")
    }),
    ("EscapeShortcut recognizes Control Option Escape", {
        try expectTrue(
            EscapeShortcut.isEscape(keyCode: 53, modifiers: [.control, .option]),
            "control option escape"
        )
    }),
    ("EscapeShortcut rejects similar shortcuts", {
        try expectFalse(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.control]), "control escape")
        try expectFalse(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.option]), "option escape")
        try expectFalse(EscapeShortcut.isEscape(keyCode: 36, modifiers: [.control, .option]), "control option enter")
        try expectFalse(EscapeShortcut.isEscape(keyCode: 53, modifiers: [.control, .option, .shift]), "extra shift")
    })
]

let passed = tests.map { run($0.0, $0.1) }.filter { $0 }.count
let failed = tests.count - passed
print("Ran \(tests.count) tests: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
