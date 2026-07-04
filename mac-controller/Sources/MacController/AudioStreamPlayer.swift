import AVFoundation
import Foundation
import MacBridgeCore

final class AudioStreamPlayer: @unchecked Sendable {
    private let inputStream: InputStream
    private let volume: Float
    private let muted: Bool
    private let onTermination: @Sendable (Error?) -> Void
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let stateLock = NSLock()
    private var worker: Thread?
    private var running = true
    private var playbackFormat: AVAudioFormat?
    private var sourceMetadata: WindowsAudioMetadata?
    private var receivedFrameCount = 0
    private var receivedPcmBytes = 0
    private var statisticsStartedAt: Date?
    private var nextStatisticsLogAt = 5.0

    init(
        inputStream: InputStream,
        volume: Double,
        muted: Bool,
        onTermination: @escaping @Sendable (Error?) -> Void
    ) {
        self.inputStream = inputStream
        self.volume = Float(min(max(volume, 0), 1))
        self.muted = muted
        self.onTermination = onTermination
    }

    func start() {
        worker = Thread { [weak self] in
            self?.run()
        }
        worker?.name = "AudioStreamPlayer"
        worker?.start()
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        playerNode.stop()
        engine.stop()
    }

    private func run() {
        var terminationError: Error?
        defer { onTermination(terminationError) }
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
                try configurePlaybackIfNeeded(for: frame.metadata)
                guard let playbackFormat,
                      let buffer = makeBuffer(frame: frame, playbackFormat: playbackFormat) else {
                    throw RuntimeError("failed to create PCM playback buffer")
                }

                playerNode.scheduleBuffer(buffer)
                record(frame: frame)
            }
        } catch {
            terminationError = error
            if shouldRun {
                print("audio playback failed: \(error)")
            }
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

        print(
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
        print(
            "audio engine running=\(engine.isRunning) playerNode playing=\(playerNode.isPlaying) outputVolume=\(engine.mainMixerNode.outputVolume)"
        )
    }

    private func makeBuffer(frame: WindowsAudioFrame, playbackFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let metadata = frame.metadata
        guard let encoding = metadata.encoding,
              metadata.frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(metadata.frameCount)
              ),
              let channelData = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(metadata.frameCount)
        let bytesPerSample = metadata.bitsPerSample / 8
        for frameIndex in 0..<metadata.frameCount {
            let frameOffset = frameIndex * metadata.blockAlign
            for channelIndex in 0..<metadata.channels {
                let sampleOffset = frameOffset + channelIndex * bytesPerSample
                channelData[channelIndex][frameIndex] = sampleValue(
                    data: frame.pcm,
                    offset: sampleOffset,
                    encoding: encoding
                )
            }
        }
        return buffer
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

    private func record(frame: WindowsAudioFrame) {
        receivedFrameCount += 1
        receivedPcmBytes += frame.pcm.count
        if statisticsStartedAt == nil {
            statisticsStartedAt = Date()
        }
        guard let statisticsStartedAt else { return }

        let elapsed = Date().timeIntervalSince(statisticsStartedAt)
        if elapsed >= nextStatisticsLogAt {
            print(
                String(
                    format: "audio receive stats elapsed=%.1fs frames=%d pcmBytes=%d engineRunning=%@ playerPlaying=%@",
                    elapsed,
                    receivedFrameCount,
                    receivedPcmBytes,
                    engine.isRunning.description,
                    playerNode.isPlaying.description
                )
            )
            nextStatisticsLogAt += 5
        }
    }

    private var shouldRun: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func readExactly(byteCount: Int) throws -> Data? {
        try ExactByteReader.read(byteCount: byteCount) { pointer, maximumLength in
            let count = inputStream.read(pointer, maxLength: maximumLength)
            if count < 0 {
                throw inputStream.streamError ?? RuntimeError("audio stream read failed")
            }
            return count
        }
    }
}
