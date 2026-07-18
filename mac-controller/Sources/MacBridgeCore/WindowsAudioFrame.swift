import Foundation

public enum WindowsAudioEncoding: String, Equatable {
    case pcm16
    case pcm24
    case pcm32
    case float32
}

public struct WindowsAudioMetadata: Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let formatTag: UInt16
    public let blockAlign: Int
    public let frameCount: Int
    public let qpcPosition: UInt64

    public var encoding: WindowsAudioEncoding? {
        switch (formatTag, bitsPerSample) {
        case (1, 16), (0xFFFE, 16): return .pcm16
        case (1, 24), (0xFFFE, 24): return .pcm24
        case (1, 32): return .pcm32
        case (3, 32), (0xFFFE, 32): return .float32
        default: return nil
        }
    }
}

public struct WindowsAudioFrame: Equatable {
    public let metadata: WindowsAudioMetadata
    public let pcm: Data
}

public enum WindowsAudioFrameError: Error, CustomStringConvertible, Equatable {
    case invalidHeaderLength(Int)
    case unexpectedMessageType(UInt8)
    case invalidPayloadLength(Int)
    case invalidMetadata(String)
    case pcmLength(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidHeaderLength(let length):
            return "audio frame header must be 5 bytes, got \(length)"
        case .unexpectedMessageType(let type):
            return String(format: "unexpected audio message type 0x%02X", type)
        case .invalidPayloadLength(let length):
            return "invalid audio payload length \(length)"
        case .invalidMetadata(let reason):
            return "invalid audio metadata: \(reason)"
        case .pcmLength(let expected, let actual):
            return "PCM length mismatch expected=\(expected) actual=\(actual)"
        }
    }
}

public enum WindowsAudioFrameProtocol {
    public static let messageType: UInt8 = 0xA1
    public static let headerLength = 5
    public static let metadataLength = 24
    public static let maximumPayloadLength = 16 * 1024 * 1024

    public static func payloadLength(from header: Data) throws -> Int {
        guard header.count == headerLength else {
            throw WindowsAudioFrameError.invalidHeaderLength(header.count)
        }
        guard header[0] == messageType else {
            throw WindowsAudioFrameError.unexpectedMessageType(header[0])
        }

        let length = Int(Int32(bitPattern: uint32(header, offset: 1)))
        guard length >= metadataLength, length <= maximumPayloadLength else {
            throw WindowsAudioFrameError.invalidPayloadLength(length)
        }
        return length
    }

    public static func parse(payload: Data) throws -> WindowsAudioFrame {
        guard payload.count >= metadataLength, payload.count <= maximumPayloadLength else {
            throw WindowsAudioFrameError.invalidPayloadLength(payload.count)
        }

        let sampleRate = Int(Int32(bitPattern: uint32(payload, offset: 0)))
        let channels = Int(uint16(payload, offset: 4))
        let bitsPerSample = Int(uint16(payload, offset: 6))
        let formatTag = uint16(payload, offset: 8)
        let blockAlign = Int(uint16(payload, offset: 10))
        let frameCount = Int(Int32(bitPattern: uint32(payload, offset: 12)))
        let qpcPosition = uint64(payload, offset: 16)

        guard sampleRate > 0 else {
            throw WindowsAudioFrameError.invalidMetadata("sampleRate must be positive")
        }
        guard channels > 0 else {
            throw WindowsAudioFrameError.invalidMetadata("channels must be positive")
        }
        guard bitsPerSample > 0, bitsPerSample % 8 == 0 else {
            throw WindowsAudioFrameError.invalidMetadata("bitsPerSample must be byte-aligned")
        }
        guard blockAlign >= channels * (bitsPerSample / 8) else {
            throw WindowsAudioFrameError.invalidMetadata("blockAlign is smaller than one sample frame")
        }
        guard frameCount >= 0 else {
            throw WindowsAudioFrameError.invalidMetadata("frameCount must not be negative")
        }

        let pcm = payload.subdata(in: metadataLength..<payload.count)
        let expectedPcmLength = frameCount * blockAlign
        guard pcm.count == expectedPcmLength else {
            throw WindowsAudioFrameError.pcmLength(expected: expectedPcmLength, actual: pcm.count)
        }

        return WindowsAudioFrame(
            metadata: WindowsAudioMetadata(
                sampleRate: sampleRate,
                channels: channels,
                bitsPerSample: bitsPerSample,
                formatTag: formatTag,
                blockAlign: blockAlign,
                frameCount: frameCount,
                qpcPosition: qpcPosition
            ),
            pcm: pcm
        )
    }

    private static func uint16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func uint64(_ data: Data, offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            result |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return result
    }
}

public enum ExactByteReaderError: Error, CustomStringConvertible, Equatable {
    case truncated(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .truncated(let expected, let actual):
            return "stream closed after \(actual) of \(expected) bytes"
        }
    }
}

public enum ExactByteReaderStreamError: Error, CustomStringConvertible, Equatable {
    case missingStreamError
    case unexpectedStatus(Int)

    public var description: String {
        switch self {
        case .missingStreamError:
            return "InputStream reported an error without streamError"
        case .unexpectedStatus(let status):
            return "InputStream returned zero bytes with unexpected status \(status)"
        }
    }
}

public enum ExactByteReader {
    public static func read(
        byteCount: Int,
        reader: (UnsafeMutablePointer<UInt8>, Int) throws -> Int
    ) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = try buffer.withUnsafeMutableBufferPointer { pointer in
                try reader(pointer.baseAddress! + offset, byteCount - offset)
            }
            if count == 0 {
                if offset == 0 { return nil }
                throw ExactByteReaderError.truncated(expected: byteCount, actual: offset)
            }
            precondition(count > 0 && count <= byteCount - offset, "reader returned an invalid byte count")
            offset += count
        }
        return Data(buffer)
    }

    public static func read(
        byteCount: Int,
        from inputStream: InputStream,
        retryDelay: TimeInterval = 0.005,
        onZeroRead: ((Stream.Status, Error?, Int) -> Void)? = nil
    ) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        var offset = 0

        while offset < byteCount {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                inputStream.read(
                    pointer.baseAddress! + offset,
                    maxLength: byteCount - offset
                )
            }

            if count > 0 {
                precondition(count <= byteCount - offset, "InputStream returned an invalid byte count")
                offset += count
                continue
            }

            if count < 0 {
                throw inputStream.streamError ?? ExactByteReaderStreamError.missingStreamError
            }

            let status = inputStream.streamStatus
            let streamError = inputStream.streamError
            onZeroRead?(status, streamError, offset)

            switch status {
            case .atEnd:
                if offset == 0 {
                    return nil
                }
                throw ExactByteReaderError.truncated(expected: byteCount, actual: offset)
            case .error:
                throw streamError ?? ExactByteReaderStreamError.missingStreamError
            case .open, .opening, .reading:
                if retryDelay > 0 {
                    Thread.sleep(forTimeInterval: retryDelay)
                }
            case .notOpen, .writing, .closed:
                throw ExactByteReaderStreamError.unexpectedStatus(
                    Int(status.rawValue)
                )
            @unknown default:
                throw ExactByteReaderStreamError.unexpectedStatus(
                    Int(status.rawValue)
                )
            }
        }

        return Data(buffer)
    }
}
