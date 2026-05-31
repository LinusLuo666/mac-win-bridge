namespace WindowsAgent;

public enum KeyboardStrokeKind
{
    Down,
    Up
}

public sealed record KeyboardStroke(ushort VirtualKey, KeyboardStrokeKind Kind);

public sealed class KeyboardInputPlanner
{
    private static readonly IReadOnlyDictionary<string, ushort> ModifierKeys =
        new Dictionary<string, ushort>
        {
            ["shift"] = 0x10,
            ["control"] = 0x11,
            ["option"] = 0x12
        };

    private readonly HashSet<ushort> _activeModifiers = new();

    public IReadOnlyList<KeyboardStroke> Plan(KeyboardMessage message)
    {
        var desiredModifiers = message.Modifiers
            .Where(ModifierKeys.ContainsKey)
            .Select(modifier => ModifierKeys[modifier])
            .ToHashSet();

        var strokes = SynchronizeModifiers(desiredModifiers);

        if (message.Event == "flagsChanged")
        {
            return strokes;
        }

        if (!WindowsKeyMapper.TryMap(message.Key, out var virtualKey))
        {
            return strokes;
        }

        strokes.Add(new KeyboardStroke(
            virtualKey,
            message.Event == "up" ? KeyboardStrokeKind.Up : KeyboardStrokeKind.Down));
        return strokes;
    }

    public IReadOnlyList<KeyboardStroke> ReleaseAllModifiers()
    {
        var strokes = _activeModifiers
            .OrderByDescending(static virtualKey => virtualKey)
            .Select(static virtualKey => new KeyboardStroke(virtualKey, KeyboardStrokeKind.Up))
            .ToArray();

        _activeModifiers.Clear();
        return strokes;
    }

    private List<KeyboardStroke> SynchronizeModifiers(HashSet<ushort> desiredModifiers)
    {
        var strokes = new List<KeyboardStroke>();

        foreach (var virtualKey in _activeModifiers.Except(desiredModifiers).OrderByDescending(static key => key))
        {
            strokes.Add(new KeyboardStroke(virtualKey, KeyboardStrokeKind.Up));
        }

        foreach (var virtualKey in desiredModifiers.Except(_activeModifiers).OrderBy(static key => key))
        {
            strokes.Add(new KeyboardStroke(virtualKey, KeyboardStrokeKind.Down));
        }

        _activeModifiers.Clear();
        _activeModifiers.UnionWith(desiredModifiers);
        return strokes;
    }
}
