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
    }

    func send(_ line: String) throws {
        guard let outputStream else {
            throw RuntimeError("TCP output stream is not connected")
        }

        let bytes = Array(line.utf8)
        let written = outputStream.write(bytes, maxLength: bytes.count)
        if written != bytes.count {
            throw RuntimeError("failed to send full message")
        }
    }

    func audioInputStream() throws -> InputStream {
        guard let inputStream else {
            throw RuntimeError("TCP input stream is not connected")
        }

        return inputStream
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
    let volume: Double
    let muted: Bool

    static func parse(_ args: [String]) -> ControllerOptions? {
        guard args.count >= 3, let port = Int(args[2]) else {
            return nil
        }

        var keyboardEnabled = true
        var audioEnabled = false
        var audioMode = AudioBridgeMode.lowLatency
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
            volume: volume,
            muted: muted
        )
    }
}

let args = CommandLine.arguments
guard let options = ControllerOptions.parse(args) else {
    print("usage: mac-controller <windows-host> <port> [--audio|--audio-only] [--audio-mode lowLatency|stable] [--volume 0.0-1.0] [--muted]")
    exit(64)
}

guard !options.keyboardEnabled || AXIsProcessTrusted() else {
    print("missing Accessibility/Input Monitoring permission for keyboard event capture")
    exit(77)
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
            muted: options.muted
        )
        audioPlayer?.start()
        try sender.send(AudioControlMessage(
            enabled: true,
            mode: options.audioMode,
            volume: options.volume,
            muted: options.muted
        ).jsonLine())
        print("audio bridge requested mode=\(options.audioMode.rawValue)")
    } catch {
        print("audio setup failed: \(error)")
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
} else {
    print("audio-only mode connected to \(options.windowsHost):\(options.port); keyboard remains local")
    CFRunLoopRun()
}

if options.audioEnabled {
    do {
        try sender.send(AudioControlMessage(
            enabled: false,
            mode: options.audioMode,
            volume: options.volume,
            muted: true
        ).jsonLine())
    } catch {
        print("audio shutdown message failed: \(error)")
    }

    audioPlayer?.stop()
}
