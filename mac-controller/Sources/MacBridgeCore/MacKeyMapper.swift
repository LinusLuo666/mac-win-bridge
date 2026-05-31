import Foundation

public enum MacKeyMapper {
    private static let mapping: [Int: String] = [
        0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF",
        5: "KeyG", 4: "KeyH", 34: "KeyI", 38: "KeyJ", 40: "KeyK", 37: "KeyL",
        46: "KeyM", 45: "KeyN", 31: "KeyO", 35: "KeyP", 12: "KeyQ", 15: "KeyR",
        1: "KeyS", 17: "KeyT", 32: "KeyU", 9: "KeyV", 13: "KeyW", 7: "KeyX",
        16: "KeyY", 6: "KeyZ",
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5",
        22: "Digit6", 26: "Digit7", 28: "Digit8", 25: "Digit9", 29: "Digit0",
        36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
        117: "Delete", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown",
        126: "ArrowUp",
        27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight",
        42: "Backslash", 41: "Semicolon", 39: "Quote", 43: "Comma",
        47: "Period", 44: "Slash", 50: "Backquote"
    ]

    public static func stableKey(for keyCode: Int) -> String? {
        mapping[keyCode]
    }
}
