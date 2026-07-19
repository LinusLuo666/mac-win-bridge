import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import MacBridgeCore

setbuf(stdout, nil)

final class TcpLineSender {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    func connect(host: String, port: Int) throws {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)

        guard let read = readStream?.takeRetainedValue(),
              let write = writeStream?.takeRetainedValue() else {
            throw RuntimeError("failed to create TCP streams")
        }

        inputStream = read
        outputStream = write
        inputStream?.open()
        outputStream?.open()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if outputStream?.streamStatus == .open || outputStream?.hasSpaceAvailable == true {
                return
            }
            if outputStream?.streamStatus == .error {
                throw outputStream?.streamError ?? RuntimeError("TCP connection failed")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        close()
        throw RuntimeError("TCP connection timed out after 5 seconds")
    }

    func send(_ line: String) throws {
        guard let outputStream else {
            throw RuntimeError("TCP output stream is not connected")
        }

        let bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { pointer in
                outputStream.write(pointer.baseAddress! + offset, maxLength: bytes.count - offset)
            }
            if written <= 0 {
                throw outputStream.streamError ?? RuntimeError("failed to send full message")
            }
            offset += written
        }
    }

    func audioInputStream() throws -> InputStream {
        guard let inputStream else {
            throw RuntimeError("TCP input stream is not connected")
        }

        return inputStream
    }

    func close() {
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

final class KeyboardForwarder {
    private let sender: TcpLineSender
    private var sequence = 0

    init(sender: TcpLineSender) {
        self.sender = sender
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifiers(from: event.flags)

        if EscapeShortcut.isEscape(keyCode: keyCode, modifiers: modifiers) {
            print("escape shortcut received; stopping forwarding")
            CFRunLoopStop(CFRunLoopGetMain())
            return nil
        }

        guard let stableKey = MacKeyMapper.stableKey(for: keyCode) else {
            print("unsupported keyCode=\(keyCode)")
            return Unmanaged.passUnretained(event)
        }

        guard let eventKind = Self.eventKind(from: type) else {
            return Unmanaged.passUnretained(event)
        }

        sequence += 1
        let message = KeyboardMessage(
            event: eventKind,
            key: stableKey,
            modifiers: Array(modifiers),
            sequence: sequence
        )

        do {
            try sender.send(message.jsonLine())
            print("forwarded sequence=\(sequence) event=\(eventKind.rawValue) key=\(stableKey)")
            return nil
        } catch {
            print("send failed: \(error)")
            CFRunLoopStop(CFRunLoopGetMain())
            return nil
        }
    }

    private static func eventKind(from type: CGEventType) -> KeyboardEventKind? {
        switch type {
        case .keyDown:
            return .down
        case .keyUp:
            return .up
        case .flagsChanged:
            return .flagsChanged
        default:
            return nil
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> Set<KeyboardModifier> {
        var modifiers = Set<KeyboardModifier>()
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlphaShift) { modifiers.insert(.capsLock) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.fn) }
        return modifiers
    }
}

struct ControllerOptions {
    let windowsHost: String
    let port: Int
    let keyboardEnabled: Bool
    let audioEnabled: Bool
    let audioMode: AudioBridgeMode
    let audioLatencyMilliseconds: Int
    let volume: Double
    let muted: Bool

    static func parse(_ args: [String]) -> ControllerOptions? {
        guard args.count >= 3, let port = Int(args[2]) else {
            return nil
        }

        var keyboardEnabled = true
        var audioEnabled = false
        var audioMode = AudioBridgeMode.lowLatency
        var audioLatencyMilliseconds = AudioLatencySetting.defaultMilliseconds
        var volume = 1.0
        var muted = false
        var index = 3

        while index < args.count {
            switch args[index] {
            case "--audio":
                audioEnabled = true
                index += 1
            case "--audio-only":
                keyboardEnabled = false
                audioEnabled = true
                index += 1
            case "--audio-mode":
                guard index + 1 < args.count,
                      let mode = AudioBridgeMode(rawValue: args[index + 1]) else {
                    return nil
                }

                audioMode = mode
                index += 2
            case "--audio-latency-ms":
                guard index + 1 < args.count,
                      let latency = AudioLatencySetting.parse(args[index + 1]) else {
                    return nil
                }

                audioLatencyMilliseconds = latency
                index += 2
            case "--volume":
                guard index + 1 < args.count,
                      let parsedVolume = Double(args[index + 1]) else {
                    return nil
                }

                volume = min(max(parsedVolume, 0), 1)
                index += 2
            case "--muted":
                muted = true
                index += 1
            default:
                return nil
            }
        }

        return ControllerOptions(
            windowsHost: args[1],
            port: port,
            keyboardEnabled: keyboardEnabled,
            audioEnabled: audioEnabled,
            audioMode: audioMode,
            audioLatencyMilliseconds: audioLatencyMilliseconds,
            volume: volume,
            muted: muted
        )
    }
}

func audioControlMessage(options: ControllerOptions, enabled: Bool) throws -> String {
    try AudioControlMessage(
        enabled: enabled,
        mode: options.audioMode,
        volume: options.volume,
        muted: enabled ? options.muted : true
    ).jsonLine()
}

func runAudioOnly(options: ControllerOptions) -> Never {
    var backoff = ReconnectBackoff()

    while true {
        let sender = TcpLineSender()
        let disconnected = DispatchSemaphore(value: 0)
        var player: AudioStreamPlayer?
        var connectedAt: Date?

        do {
            try sender.connect(host: options.windowsHost, port: options.port)
            connectedAt = Date()
            player = try AudioStreamPlayer(
                inputStream: sender.audioInputStream(),
                volume: options.volume,
                muted: options.muted,
                latencyMilliseconds: options.audioLatencyMilliseconds,
                onTermination: { error in
                    if let error {
                        AudioRuntimeLog.write("audio connection ended: \(error)")
                    } else {
                        AudioRuntimeLog.write("audio connection closed by Windows")
                    }
                    disconnected.signal()
                }
            )
            player?.start()
            try sender.send(audioControlMessage(options: options, enabled: true))
            AudioRuntimeLog.write(
                "audio bridge requested mode=\(options.audioMode.rawValue) latencyMs=\(options.audioLatencyMilliseconds)"
            )
            AudioRuntimeLog.write("audio-only mode connected to \(options.windowsHost):\(options.port); keyboard remains local")
            disconnected.wait()
        } catch {
            AudioRuntimeLog.write("audio-only connection failed: \(error)")
        }

        player?.stop()
        sender.close()

        if let connectedAt, Date().timeIntervalSince(connectedAt) >= 10 {
            backoff.reset()
        }
        let delay = backoff.nextDelay()
        AudioRuntimeLog.write(String(format: "reconnecting to %@:%d in %.0f seconds", options.windowsHost, options.port, delay))
        Thread.sleep(forTimeInterval: delay)
    }
}

let args = CommandLine.arguments
guard let options = ControllerOptions.parse(args) else {
    print("usage: mac-controller <windows-host> <port> [--audio|--audio-only] [--audio-mode lowLatency|stable] [--audio-latency-ms 10-120] [--volume 0.0-1.0] [--muted]")
    exit(64)
}

guard !options.keyboardEnabled || AXIsProcessTrusted() else {
    print("missing Accessibility/Input Monitoring permission for keyboard event capture")
    exit(77)
}

if !options.keyboardEnabled && options.audioEnabled {
    runAudioOnly(options: options)
}

let sender = TcpLineSender()
do {
    try sender.connect(host: options.windowsHost, port: options.port)
} catch {
    print("connection failed: \(error)")
    exit(69)
}

let audioPlayer: AudioStreamPlayer?
if options.audioEnabled {
    do {
        audioPlayer = try AudioStreamPlayer(
            inputStream: sender.audioInputStream(),
            volume: options.volume,
            muted: options.muted,
            latencyMilliseconds: options.audioLatencyMilliseconds,
            onTermination: { error in
                if let error {
                    AudioRuntimeLog.write("audio connection ended: \(error)")
                }
                CFRunLoopStop(CFRunLoopGetMain())
            }
        )
        audioPlayer?.start()
        try sender.send(audioControlMessage(options: options, enabled: true))
        AudioRuntimeLog.write(
            "audio bridge requested mode=\(options.audioMode.rawValue) latencyMs=\(options.audioLatencyMilliseconds)"
        )
    } catch {
        AudioRuntimeLog.write("audio setup failed: \(error)")
        exit(69)
    }
} else {
    audioPlayer = nil
}

if options.keyboardEnabled {
    let forwarder = KeyboardForwarder(sender: sender)
    let mask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { proxy, type, event, refcon in
            let forwarder = Unmanaged<KeyboardForwarder>.fromOpaque(refcon!).takeUnretainedValue()
            return forwarder.handle(proxy: proxy, type: type, event: event)
        },
        userInfo: Unmanaged.passUnretained(forwarder).toOpaque()
    ) else {
        print("failed to create CGEventTap")
        exit(77)
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("forwarding keyboard events to \(options.windowsHost):\(options.port); press Control+Option+Escape to stop")
    CFRunLoopRun()
}

if options.audioEnabled {
    do {
        try sender.send(audioControlMessage(options: options, enabled: false))
    } catch {
        AudioRuntimeLog.write("audio shutdown message failed: \(error)")
    }

    audioPlayer?.stop()
}
sender.close()
