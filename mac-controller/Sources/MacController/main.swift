import ApplicationServices
import CoreGraphics
import Foundation
import MacBridgeCore

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

let args = CommandLine.arguments
guard args.count == 3, let port = Int(args[2]) else {
    print("usage: mac-controller <windows-host> <port>")
    exit(64)
}

guard AXIsProcessTrusted() else {
    print("missing Accessibility/Input Monitoring permission for keyboard event capture")
    exit(77)
}

let sender = TcpLineSender()
do {
    try sender.connect(host: args[1], port: port)
} catch {
    print("connection failed: \(error)")
    exit(69)
}

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
print("forwarding keyboard events to \(args[1]):\(port); press Control+Option+Escape to stop")
CFRunLoopRun()
