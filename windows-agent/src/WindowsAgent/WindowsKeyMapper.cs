namespace WindowsAgent;

public static class WindowsKeyMapper
{
    private static readonly IReadOnlyDictionary<string, ushort> Keys = new Dictionary<string, ushort>
    {
        ["KeyA"] = 0x41, ["KeyB"] = 0x42, ["KeyC"] = 0x43, ["KeyD"] = 0x44,
        ["KeyE"] = 0x45, ["KeyF"] = 0x46, ["KeyG"] = 0x47, ["KeyH"] = 0x48,
        ["KeyI"] = 0x49, ["KeyJ"] = 0x4A, ["KeyK"] = 0x4B, ["KeyL"] = 0x4C,
        ["KeyM"] = 0x4D, ["KeyN"] = 0x4E, ["KeyO"] = 0x4F, ["KeyP"] = 0x50,
        ["KeyQ"] = 0x51, ["KeyR"] = 0x52, ["KeyS"] = 0x53, ["KeyT"] = 0x54,
        ["KeyU"] = 0x55, ["KeyV"] = 0x56, ["KeyW"] = 0x57, ["KeyX"] = 0x58,
        ["KeyY"] = 0x59, ["KeyZ"] = 0x5A,
        ["Digit0"] = 0x30, ["Digit1"] = 0x31, ["Digit2"] = 0x32, ["Digit3"] = 0x33,
        ["Digit4"] = 0x34, ["Digit5"] = 0x35, ["Digit6"] = 0x36, ["Digit7"] = 0x37,
        ["Digit8"] = 0x38, ["Digit9"] = 0x39,
        ["Enter"] = 0x0D, ["Tab"] = 0x09, ["Space"] = 0x20, ["Backspace"] = 0x08,
        ["Escape"] = 0x1B, ["Delete"] = 0x2E, ["ArrowLeft"] = 0x25,
        ["ArrowRight"] = 0x27, ["ArrowDown"] = 0x28, ["ArrowUp"] = 0x26,
        ["Minus"] = 0xBD, ["Equal"] = 0xBB, ["BracketLeft"] = 0xDB,
        ["BracketRight"] = 0xDD, ["Backslash"] = 0xDC, ["Semicolon"] = 0xBA,
        ["Quote"] = 0xDE, ["Comma"] = 0xBC, ["Period"] = 0xBE, ["Slash"] = 0xBF,
        ["Backquote"] = 0xC0
    };

    public static bool TryMap(string stableKey, out ushort virtualKey) {
        return Keys.TryGetValue(stableKey, out virtualKey);
    }
}
