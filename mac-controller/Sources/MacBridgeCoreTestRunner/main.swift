import Foundation
import MacBridgeCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
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
