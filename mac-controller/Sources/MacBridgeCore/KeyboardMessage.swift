import Foundation

public enum KeyboardEventKind: String, Codable, Equatable {
    case down
    case up
    case flagsChanged
}

public enum KeyboardModifier: String, Codable, Equatable, Comparable {
    case shift
    case control
    case option
    case command
    case capsLock
    case fn

    public static func < (lhs: KeyboardModifier, rhs: KeyboardModifier) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ modifier: KeyboardModifier) -> Int {
        switch modifier {
        case .shift: return 0
        case .control: return 1
        case .option: return 2
        case .command: return 3
        case .capsLock: return 4
        case .fn: return 5
        }
    }
}

public struct KeyboardMessage: Codable, Equatable {
    public let type: String
    public let event: KeyboardEventKind
    public let key: String
    public let modifiers: [KeyboardModifier]
    public let sequence: Int

    public init(event: KeyboardEventKind, key: String, modifiers: [KeyboardModifier], sequence: Int) {
        self.type = "key"
        self.event = event
        self.key = key
        self.modifiers = modifiers.sorted()
        self.sequence = sequence
    }

    public func jsonLine() throws -> String {
        let modifierValues = modifiers.map { #"""# + Self.escape($0.rawValue) + #"""# }.joined(separator: ",")
        return #"{"type":"\#(type)","event":"\#(event.rawValue)","key":"\#(Self.escape(key))","modifiers":[\#(modifierValues)],"sequence":\#(sequence)}"# + "\n"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }
}
