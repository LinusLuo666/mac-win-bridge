using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsAgent;

public sealed record KeyboardMessage(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("event")] string Event,
    [property: JsonPropertyName("key")] string Key,
    [property: JsonPropertyName("modifiers")] string[] Modifiers,
    [property: JsonPropertyName("sequence")] long Sequence)
{
    public static KeyboardMessage? Parse(string line)
    {
        try
        {
            var message = JsonSerializer.Deserialize<KeyboardMessage>(line);
            return message is { Type: ProtocolMessageType.Key } ? message : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
