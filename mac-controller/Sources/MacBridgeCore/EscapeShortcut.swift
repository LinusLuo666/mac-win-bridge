import Foundation

public enum EscapeShortcut {
    public static func isEscape(keyCode: Int, modifiers: Set<KeyboardModifier>) -> Bool {
        keyCode == 53 && modifiers == [.control, .option]
    }
}
