using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsAgent;

public sealed record AudioControlMessage(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("enabled")] bool Enabled,
    [property: JsonPropertyName("mode")] string? Mode)
{
    public static AudioControlMessage? Parse(string line)
    {
        try
        {
            var message = JsonSerializer.Deserialize<AudioControlMessage>(line);
            return message is { Type: "audioControl" } ? message : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public AudioCaptureMode CaptureMode =>
        string.Equals(Mode, "stable", StringComparison.OrdinalIgnoreCase)
            ? AudioCaptureMode.Stable
            : AudioCaptureMode.LowLatency;
}
