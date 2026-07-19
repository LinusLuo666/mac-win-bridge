import AVFoundation
import Foundation
import MacBridgeCore

private struct AudioPipelineTotals {
    let receivedInputBuffers: Int
    let receivedInputSampleFrames: Int
    let reblockedOutputBuffers: Int
    let reblockedOutputSampleFrames: Int
    let scheduledOutputBuffers: Int
    let scheduledOutputSampleFrames: Int
    let completedOutputBuffers: Int
    let completedOutputSampleFrames: Int
    let carrySampleFrames: Int
    let qpcJumps: Int
    let jitterBuffer: PCMOutputJitterBufferSnapshot
}

final class AudioStreamPlayer: @unchecked Sendable {
    private let inputStream: InputStream
    private let volume: Float
    private let muted: Bool
    private let onTermination: @Sendable (Error?) -> Void
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let bufferQueueLimiter = AudioBufferQueueLimiter(maximumPendingBuffers: 2)
    private let reblocker = PCMReblocker()
    private let jitterBuffer: PCMOutputJitterBuffer
    private let stateLock = NSLock()
    private let statisticsLock = NSLock()
    private let evidenceQueue = DispatchQueue(
        label: "AudioStreamEvidence",
        qos: .utility
    )
    private var receiverWorker: Thread?
    private var playbackWorker: Thread?
    private var evidenceTimer: DispatchSourceTimer?
    private var running = true
    private var terminationReported = false
    private var playbackFormat: AVAudioFormat?
    private var sourceMetadata: WindowsAudioMetadata?
    private var receivedInputBuffers = 0
    private var receivedInputSampleFrames = 0
    private var reblockedOutputBuffers = 0
    private var reblockedOutputSampleFrames = 0
    private var scheduledOutputBuffers = 0
    private var scheduledOutputSampleFrames = 0
    private var completedOutputBuffers = 0
    private var completedOutputSampleFrames = 0
    private var carrySampleFrames = 0
    private var qpcJumps = 0
    private var qpcJumpTracker = AudioQPCJumpTracker()
    private var statisticsStartedAt: Date?
    private var nextStatisticsLogAt = 5.0
    private var evidenceWindowTracker: AudioPipelineEvidenceWindowTracker
    private var nextEvidenceWindowEnd: Date
    private var arrivalBatchTracker = AudioArrivalBatchTracker()
    private var loggedTemporaryZeroRead = false
    private var recordedTrimmedOutputBuffers = 0
    private var recordedTrimmedOutputSampleFrames = 0
    private var recordedUnderrunCount = 0
    private var recordedRebufferCount = 0
    private var recordedRebufferDurationMilliseconds = 0

    init(
        inputStream: InputStream,
        volume: Double,
        muted: Bool,
        latencyMilliseconds: Int = AudioLatencySetting.defaultMilliseconds,
        onTermination: @escaping @Sendable (Error?) -> Void
    ) {
        self.inputStream = inputStream
        self.volume = Float(min(max(volume, 0), 1))
        self.muted = muted
        jitterBuffer = PCMOutputJitterBuffer(
            requestedLatencyMilliseconds: latencyMilliseconds
        )
        self.onTermination = onTermination
        let evidenceWindow = AudioEvidenceClock.alignedWindow(
            containing: Date(),
            duration: 5
        )
        evidenceWindowTracker = AudioPipelineEvidenceWindowTracker(
            windowStart: evidenceWindow.start
        )
        nextEvidenceWindowEnd = evidenceWindow.end
    }

    func start() {
        AudioRuntimeLog.write(
            "audio input stream before receiver status=\(inputStream.streamStatus.rawValue) error=\(inputStream.streamError.map(String.init(describing:)) ?? "none")"
        )
        startEvidenceLogging()
        playbackWorker = Thread { [weak self] in
            self?.playbackLoop()
        }
        playbackWorker?.name = "AudioStreamPlayback"
        playbackWorker?.start()

        receiverWorker = Thread { [weak self] in
            self?.receiveLoop()
        }
        receiverWorker?.name = "AudioStreamReceiver"
        receiverWorker?.start()
    }

    func stop() {
        stateLock.lock()
        running = false
        terminationReported = true
        stateLock.unlock()
        stopEvidenceLogging()
        flushArrivalBatch()
        jitterBuffer.stop()
        bufferQueueLimiter.stop()
        reblocker.stop()
        playerNode.stop()
        engine.stop()
    }

    private func receiveLoop() {
        var terminationError: Error?
        do {
            while shouldRun {
                guard let header = try readExactly(byteCount: WindowsAudioFrameProtocol.headerLength) else {
                    break
                }
                let payloadLength = try WindowsAudioFrameProtocol.payloadLength(from: header)
                guard let payload = try readExactly(byteCount: payloadLength) else {
                    throw RuntimeError("audio stream closed before payload")
                }

                let frame = try WindowsAudioFrameProtocol.parse(payload: payload)
                recordReceived(frame: frame)
                try configurePlaybackIfNeeded(for: frame.metadata)
                let outputs = try reblocker.append(decodeInputBlock(frame: frame))
                recordReblocked(outputs: outputs, carrySampleFrames: reblocker.carrySampleFrames)
                let enqueueResult = jitterBuffer.enqueue(outputs)
                recordJitterBuffer(enqueueResult: enqueueResult)
            }
        } catch {
            terminationError = error
            if shouldRun {
                AudioRuntimeLog.write("audio receive failed: \(error)")
            }
        }
        finish(error: terminationError)
    }

    private func playbackLoop() {
        while shouldRun {
            guard bufferQueueLimiter.waitForSlot() else {
                return
            }
            guard let output = jitterBuffer.waitForNextToSchedule() else {
                return
            }

            let outputSampleFrames = Int(output.buffer.frameLength)
            playerNode.scheduleBuffer(output.buffer) { [weak self] in
                guard let self else {
                    return
                }
                jitterBuffer.completeScheduled(sampleFrames: outputSampleFrames)
                bufferQueueLimiter.release()
                recordCompleted(outputSampleFrames: outputSampleFrames)
                recordJitterBuffer(enqueueResult: nil)
            }
            recordScheduled(output: output)
            recordJitterBuffer(enqueueResult: nil)
        }
    }

    private func finish(error: Error?) {
        stateLock.lock()
        let shouldNotify = !terminationReported
        running = false
        terminationReported = true
        stateLock.unlock()

        stopEvidenceLogging()
        flushArrivalBatch()
        jitterBuffer.stop()
        bufferQueueLimiter.stop()
        reblocker.stop()
        if shouldNotify {
            onTermination(error)
        }
    }

    private func configurePlaybackIfNeeded(for metadata: WindowsAudioMetadata) throws {
        if let sourceMetadata {
            guard sourceMetadata.sampleRate == metadata.sampleRate,
                  sourceMetadata.channels == metadata.channels,
                  sourceMetadata.bitsPerSample == metadata.bitsPerSample,
                  sourceMetadata.formatTag == metadata.formatTag,
                  sourceMetadata.blockAlign == metadata.blockAlign else {
                throw RuntimeError("audio format changed during stream")
            }
            return
        }

        guard let encoding = metadata.encoding else {
            throw RuntimeError(
                String(format: "unsupported audio format tag=0x%04X bits=%d", metadata.formatTag, metadata.bitsPerSample)
            )
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(metadata.sampleRate),
            channels: AVAudioChannelCount(metadata.channels),
            interleaved: false
        ) else {
            throw RuntimeError("failed to create AVAudioFormat")
        }

        sourceMetadata = metadata
        playbackFormat = format
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : volume
        engine.prepare()
        try engine.start()
        playerNode.play()

        AudioRuntimeLog.write(
            String(
                format: "audio first frame sampleRate=%d channels=%d bitsPerSample=%d formatTag=0x%04X blockAlign=%d frameCount=%d qpcPosition=%llu encoding=%@ pcmBytes=%d",
                metadata.sampleRate,
                metadata.channels,
                metadata.bitsPerSample,
                metadata.formatTag,
                metadata.blockAlign,
                metadata.frameCount,
                metadata.qpcPosition,
                encoding.rawValue,
                metadata.frameCount * metadata.blockAlign
            )
        )
        AudioRuntimeLog.write(
            "audio engine running=\(engine.isRunning) playerNode playing=\(playerNode.isPlaying) outputVolume=\(engine.mainMixerNode.outputVolume)"
        )
    }

    private func decodeInputBlock(frame: WindowsAudioFrame) throws -> PCMInputBlock {
        let metadata = frame.metadata
        guard let encoding = metadata.encoding, metadata.frameCount > 0 else {
            throw RuntimeError("failed to decode PCM input frame")
        }

        var channels = Array(
            repeating: [Float](repeating: 0, count: metadata.frameCount),
            count: metadata.channels
        )
        let bytesPerSample = metadata.bitsPerSample / 8
        for frameIndex in 0..<metadata.frameCount {
            let frameOffset = frameIndex * metadata.blockAlign
            for channelIndex in 0..<metadata.channels {
                let sampleOffset = frameOffset + channelIndex * bytesPerSample
                channels[channelIndex][frameIndex] = sampleValue(
                    data: frame.pcm,
                    offset: sampleOffset,
                    encoding: encoding
                )
            }
        }
        return PCMInputBlock(
            sampleRate: metadata.sampleRate,
            qpcPosition: metadata.qpcPosition,
            channels: channels
        )
    }

    private func sampleValue(data: Data, offset: Int, encoding: WindowsAudioEncoding) -> Float {
        switch encoding {
        case .float32:
            let bits = uint32(data, offset: offset)
            let value = Float(bitPattern: bits)
            return value.isFinite ? value : 0
        case .pcm16:
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return Float(Int16(bitPattern: bits)) / 32768.0
        case .pcm24:
            var value = Int32(data[offset])
                | (Int32(data[offset + 1]) << 8)
                | (Int32(data[offset + 2]) << 16)
            if value & 0x00800000 != 0 {
                value |= ~0x00FFFFFF
            }
            return Float(value) / 8_388_608.0
        case .pcm32:
            return Float(Int32(bitPattern: uint32(data, offset: offset))) / 2_147_483_648.0
        }
    }

    private func uint32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func recordReceived(frame: WindowsAudioFrame) {
        let receivedAt = Date()
        statisticsLock.lock()
        receivedInputBuffers += 1
        receivedInputSampleFrames += frame.metadata.frameCount
        let jump = qpcJumpTracker.record(
            position: frame.metadata.qpcPosition,
            frameCount: frame.metadata.frameCount,
            sampleRate: frame.metadata.sampleRate
        )
        if jump != nil {
            qpcJumps += 1
        }
        evidenceWindowTracker.recordInput(
            sampleFrameCount: frame.metadata.frameCount,
            overwrittenSampleFrameCount: 0,
            qpcJumpActualDelta: jump?.actualDelta,
            at: receivedAt
        )
        let batch = arrivalBatchTracker.record(
            at: receivedAt,
            expectedInterval: Double(frame.metadata.frameCount) / Double(frame.metadata.sampleRate),
            dropped: false
        )
        if statisticsStartedAt == nil {
            statisticsStartedAt = Date()
        }
        let elapsed = Date().timeIntervalSince(statisticsStartedAt ?? Date())
        let shouldLog = elapsed >= nextStatisticsLogAt
        if shouldLog {
            nextStatisticsLogAt += 5
        }
        let snapshot = pipelineTotalsLocked()
        statisticsLock.unlock()

        if let jump {
            let actualDelta = jump.actualDelta.map(String.init) ?? "n/a"
            AudioRuntimeLog.write(
                "audio input qpc jump direction=\(jump.direction.rawValue) previous=\(jump.previousPosition) current=\(jump.currentPosition) actualDelta=\(actualDelta) expectedDelta=\(jump.expectedDelta)"
            )
        }
        if let batch {
            logArrivalBatch(batch)
        }

        if shouldLog {
            AudioRuntimeLog.write(
                String(
                    format: "audio stats elapsed=%.1fs receivedInputBuffers=%d receivedInputSampleFrames=%d reblockedOutputBuffers=%d reblockedOutputSampleFrames=%d scheduledOutputBuffers=%d scheduledOutputSampleFrames=%d completedOutputBuffers=%d completedOutputSampleFrames=%d carrySampleFrames=%d configuredLatencyMs=%d effectiveTargetSampleFrames=%d queuedOutputBuffers=%d queuedOutputSampleFrames=%d scheduledPendingSampleFrames=%d trimmedOutputBuffers=%d trimmedOutputSampleFrames=%d underrunCount=%d rebufferCount=%d rebufferDurationMs=%d maximumQueuedSampleFrames=%d qpcJumps=%d engineRunning=%@ playerPlaying=%@",
                    elapsed,
                    snapshot.receivedInputBuffers,
                    snapshot.receivedInputSampleFrames,
                    snapshot.reblockedOutputBuffers,
                    snapshot.reblockedOutputSampleFrames,
                    snapshot.scheduledOutputBuffers,
                    snapshot.scheduledOutputSampleFrames,
                    snapshot.completedOutputBuffers,
                    snapshot.completedOutputSampleFrames,
                    snapshot.carrySampleFrames,
                    snapshot.jitterBuffer.requestedLatencyMilliseconds,
                    snapshot.jitterBuffer.effectiveTargetSampleFrames ?? 0,
                    snapshot.jitterBuffer.queuedOutputBuffers,
                    snapshot.jitterBuffer.queuedOutputSampleFrames,
                    snapshot.jitterBuffer.scheduledPendingSampleFrames,
                    snapshot.jitterBuffer.trimmedOutputBuffers,
                    snapshot.jitterBuffer.trimmedOutputSampleFrames,
                    snapshot.jitterBuffer.underrunCount,
                    snapshot.jitterBuffer.rebufferCount,
                    snapshot.jitterBuffer.totalRebufferDurationMilliseconds,
                    snapshot.jitterBuffer.maximumQueuedSampleFrames,
                    snapshot.qpcJumps,
                    engine.isRunning.description,
                    playerNode.isPlaying.description
                )
            )
        }
    }

    private func recordReblocked(outputs: [ReblockedPCMOutput], carrySampleFrames: Int) {
        statisticsLock.lock()
        self.carrySampleFrames = carrySampleFrames
        evidenceWindowTracker.updateCarry(sampleFrameCount: carrySampleFrames)
        for output in outputs {
            let sampleFrames = Int(output.buffer.frameLength)
            reblockedOutputBuffers += 1
            reblockedOutputSampleFrames += sampleFrames
            evidenceWindowTracker.recordReblocked(
                outputSampleFrameCount: sampleFrames,
                startQPCPosition: output.startQPCPosition,
                endQPCPosition: outputEndQPCPosition(output),
                sourceSpanCount: output.sourceSpans.count
            )
        }
        statisticsLock.unlock()
    }

    private func recordScheduled(output: ReblockedPCMOutput) {
        let sampleFrames = Int(output.buffer.frameLength)
        statisticsLock.lock()
        scheduledOutputBuffers += 1
        scheduledOutputSampleFrames += sampleFrames
        evidenceWindowTracker.recordScheduled(outputSampleFrameCount: sampleFrames)
        statisticsLock.unlock()
    }

    private func recordCompleted(outputSampleFrames: Int) {
        statisticsLock.lock()
        completedOutputBuffers += 1
        completedOutputSampleFrames += outputSampleFrames
        evidenceWindowTracker.recordCompleted(outputSampleFrameCount: outputSampleFrames)
        statisticsLock.unlock()
    }

    private func recordJitterBuffer(
        enqueueResult _: PCMOutputJitterBufferEnqueueResult?
    ) {
        statisticsLock.lock()
        let snapshot = jitterBuffer.snapshot()
        let trimmedBuffersDelta = max(
            0,
            snapshot.trimmedOutputBuffers - recordedTrimmedOutputBuffers
        )
        let trimmedSampleFramesDelta = max(
            0,
            snapshot.trimmedOutputSampleFrames - recordedTrimmedOutputSampleFrames
        )
        let underrunDelta = max(0, snapshot.underrunCount - recordedUnderrunCount)
        let rebufferDelta = max(0, snapshot.rebufferCount - recordedRebufferCount)
        let rebufferDurationDelta = max(
            0,
            snapshot.totalRebufferDurationMilliseconds
                - recordedRebufferDurationMilliseconds
        )
        evidenceWindowTracker.recordJitterBuffer(
            configuredLatencyMilliseconds: snapshot.requestedLatencyMilliseconds,
            effectiveTargetSampleFrames: snapshot.effectiveTargetSampleFrames,
            queuedOutputBuffers: snapshot.queuedOutputBuffers,
            queuedOutputSampleFrames: snapshot.queuedOutputSampleFrames,
            scheduledPendingSampleFrames: snapshot.scheduledPendingSampleFrames,
            trimmedOutputBuffersDelta: trimmedBuffersDelta,
            trimmedOutputSampleFramesDelta: trimmedSampleFramesDelta,
            underrunCountDelta: underrunDelta,
            rebufferCountDelta: rebufferDelta,
            rebufferDurationMillisecondsDelta: rebufferDurationDelta,
            maximumQueuedSampleFrames: snapshot.maximumQueuedSampleFrames
        )
        recordedTrimmedOutputBuffers = snapshot.trimmedOutputBuffers
        recordedTrimmedOutputSampleFrames = snapshot.trimmedOutputSampleFrames
        recordedUnderrunCount = snapshot.underrunCount
        recordedRebufferCount = snapshot.rebufferCount
        recordedRebufferDurationMilliseconds = snapshot.totalRebufferDurationMilliseconds
        statisticsLock.unlock()
    }

    private func outputEndQPCPosition(_ output: ReblockedPCMOutput) -> UInt64 {
        guard let metadata = sourceMetadata, let lastSpan = output.sourceSpans.last else {
            return output.startQPCPosition
        }
        let sourceEndOffset = lastSpan.sourceFrameOffset + lastSpan.sampleFrameCount
        let qpcOffset = Double(sourceEndOffset) * 10_000_000 / Double(metadata.sampleRate)
        return lastSpan.qpcPosition + UInt64(qpcOffset.rounded())
    }

    private func pipelineTotalsLocked() -> AudioPipelineTotals {
        AudioPipelineTotals(
            receivedInputBuffers: receivedInputBuffers,
            receivedInputSampleFrames: receivedInputSampleFrames,
            reblockedOutputBuffers: reblockedOutputBuffers,
            reblockedOutputSampleFrames: reblockedOutputSampleFrames,
            scheduledOutputBuffers: scheduledOutputBuffers,
            scheduledOutputSampleFrames: scheduledOutputSampleFrames,
            completedOutputBuffers: completedOutputBuffers,
            completedOutputSampleFrames: completedOutputSampleFrames,
            carrySampleFrames: carrySampleFrames,
            qpcJumps: qpcJumps,
            jitterBuffer: jitterBuffer.snapshot()
        )
    }

    private func startEvidenceLogging() {
        let now = Date()
        let delay = max(0, nextEvidenceWindowEnd.timeIntervalSince(now))
        let timer = DispatchSource.makeTimerSource(queue: evidenceQueue)
        timer.schedule(
            deadline: .now() + delay,
            repeating: 5,
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in
            self?.logEvidenceWindows(through: Date())
        }

        stateLock.lock()
        evidenceTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopEvidenceLogging() {
        stateLock.lock()
        let timer = evidenceTimer
        evidenceTimer = nil
        stateLock.unlock()
        timer?.cancel()
    }

    private func logEvidenceWindows(through date: Date) {
        var records: [(AudioPipelineEvidenceWindowSnapshot, AudioPipelineTotals)] = []

        statisticsLock.lock()
        while nextEvidenceWindowEnd <= date {
            let snapshot = evidenceWindowTracker.snapshotAndReset(
                windowEnd: nextEvidenceWindowEnd
            )
            let totals = pipelineTotalsLocked()
            records.append((snapshot, totals))
            nextEvidenceWindowEnd = nextEvidenceWindowEnd.addingTimeInterval(5)
        }
        statisticsLock.unlock()

        for (snapshot, totals) in records {
            let frameCounts = snapshot.inputFrameCountDistribution
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let maximumQpcDelta = snapshot.maximumQpcDelta.map(String.init) ?? "none"
            let firstOutputQPC = snapshot.firstOutputStartQPCPosition.map(String.init) ?? "none"
            let lastOutputQPC = snapshot.lastOutputEndQPCPosition.map(String.init) ?? "none"
            AudioRuntimeLog.write(
                "audio evidence window start=\(AudioEvidenceClock.timestamp(snapshot.start)) end=\(AudioEvidenceClock.timestamp(snapshot.end)) receivedInputBuffers=\(snapshot.receivedInputBuffers) receivedInputSampleFrames=\(snapshot.receivedInputSampleFrames) reblockedOutputBuffers=\(snapshot.reblockedOutputBuffers) reblockedOutputSampleFrames=\(snapshot.reblockedOutputSampleFrames) scheduledOutputBuffers=\(snapshot.scheduledOutputBuffers) scheduledOutputSampleFrames=\(snapshot.scheduledOutputSampleFrames) completedOutputBuffers=\(snapshot.completedOutputBuffers) completedOutputSampleFrames=\(snapshot.completedOutputSampleFrames) carrySampleFrames=\(snapshot.carrySampleFrames) configuredLatencyMs=\(snapshot.configuredLatencyMilliseconds ?? 0) effectiveTargetSampleFrames=\(snapshot.effectiveTargetSampleFrames ?? 0) queuedOutputBuffers=\(snapshot.queuedOutputBuffers) queuedOutputSampleFrames=\(snapshot.queuedOutputSampleFrames) scheduledPendingSampleFrames=\(snapshot.scheduledPendingSampleFrames) trimmedOutputBuffers=\(snapshot.trimmedOutputBuffers) trimmedOutputSampleFrames=\(snapshot.trimmedOutputSampleFrames) underrunCount=\(snapshot.underrunCount) rebufferCount=\(snapshot.rebufferCount) rebufferDurationMs=\(snapshot.rebufferDurationMilliseconds) maximumQueuedSampleFrames=\(snapshot.maximumQueuedSampleFrames) inputFrameCounts=\(frameCounts.isEmpty ? "none" : frameCounts) qpcJumps=\(snapshot.qpcJumps) maxQpcDelta=\(maximumQpcDelta) maxArrivalGapMs=\(snapshot.maximumArrivalGapMilliseconds) outputSourceSpanCount=\(snapshot.outputSourceSpanCount) firstOutputStartQPC=\(firstOutputQPC) lastOutputEndQPC=\(lastOutputQPC) totalReceivedInputBuffers=\(totals.receivedInputBuffers) totalReceivedInputSampleFrames=\(totals.receivedInputSampleFrames) totalReblockedOutputBuffers=\(totals.reblockedOutputBuffers) totalReblockedOutputSampleFrames=\(totals.reblockedOutputSampleFrames) totalScheduledOutputBuffers=\(totals.scheduledOutputBuffers) totalScheduledOutputSampleFrames=\(totals.scheduledOutputSampleFrames) totalCompletedOutputBuffers=\(totals.completedOutputBuffers) totalCompletedOutputSampleFrames=\(totals.completedOutputSampleFrames) totalCarrySampleFrames=\(totals.carrySampleFrames) totalConfiguredLatencyMs=\(totals.jitterBuffer.requestedLatencyMilliseconds) totalEffectiveTargetSampleFrames=\(totals.jitterBuffer.effectiveTargetSampleFrames ?? 0) totalQueuedOutputBuffers=\(totals.jitterBuffer.queuedOutputBuffers) totalQueuedOutputSampleFrames=\(totals.jitterBuffer.queuedOutputSampleFrames) totalScheduledPendingSampleFrames=\(totals.jitterBuffer.scheduledPendingSampleFrames) totalTrimmedOutputBuffers=\(totals.jitterBuffer.trimmedOutputBuffers) totalTrimmedOutputSampleFrames=\(totals.jitterBuffer.trimmedOutputSampleFrames) totalUnderrunCount=\(totals.jitterBuffer.underrunCount) totalRebufferCount=\(totals.jitterBuffer.rebufferCount) totalRebufferDurationMs=\(totals.jitterBuffer.totalRebufferDurationMilliseconds) totalMaximumQueuedSampleFrames=\(totals.jitterBuffer.maximumQueuedSampleFrames) totalQpcJumps=\(totals.qpcJumps) engineRunning=\(engine.isRunning) playerPlaying=\(playerNode.isPlaying)",
                at: snapshot.end
            )
        }
    }

    private func flushArrivalBatch() {
        statisticsLock.lock()
        let batch = arrivalBatchTracker.finish()
        statisticsLock.unlock()
        if let batch {
            logArrivalBatch(batch)
        }
    }

    private func logArrivalBatch(_ batch: AudioArrivalBatch) {
        AudioRuntimeLog.write(
            "audio arrival batch start=\(AudioEvidenceClock.timestamp(batch.start)) end=\(AudioEvidenceClock.timestamp(batch.end)) receivedInputBuffers=\(batch.receivedFrames) engineRunning=\(engine.isRunning) playerPlaying=\(playerNode.isPlaying)",
            at: batch.end
        )
    }

    private var shouldRun: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func readExactly(byteCount: Int) throws -> Data? {
        try ExactByteReader.read(
            byteCount: byteCount,
            from: inputStream,
            onZeroRead: { [weak self] status, error, offset in
                guard let self else {
                    return
                }
                let temporary = status == .open || status == .opening || status == .reading
                if temporary {
                    guard !loggedTemporaryZeroRead else {
                        return
                    }
                    loggedTemporaryZeroRead = true
                }
                AudioRuntimeLog.write(
                    "audio input zero read status=\(status.rawValue) offset=\(offset) error=\(error.map(String.init(describing:)) ?? "none")"
                )
            }
        )
    }
}
