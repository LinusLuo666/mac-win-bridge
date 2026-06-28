using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class AudioControlMessageTests
{
    [Fact]
    public void ParsesMacEnabledLowLatencyMessage()
    {
        var message = AudioControlMessage.Parse(
            """{"type":"audioControl","enabled":true,"mode":"lowLatency","volume":1.0,"muted":false}""");

        Assert.NotNull(message);
        Assert.True(message.Enabled);
        Assert.Equal(AudioCaptureMode.LowLatency, message.CaptureMode);
    }

    [Fact]
    public void MapsStableModeToStableCaptureMode()
    {
        var message = AudioControlMessage.Parse(
            """{"type":"audioControl","enabled":true,"mode":"stable"}""");

        Assert.NotNull(message);
        Assert.Equal(AudioCaptureMode.Stable, message.CaptureMode);
    }

    [Fact]
    public void DefaultsMissingModeToLowLatency()
    {
        var message = AudioControlMessage.Parse(
            """{"type":"audioControl","enabled":true}""");

        Assert.NotNull(message);
        Assert.Equal(AudioCaptureMode.LowLatency, message.CaptureMode);
    }

    [Fact]
    public void DefaultsNullModeToLowLatency()
    {
        var message = AudioControlMessage.Parse(
            """{"type":"audioControl","enabled":true,"mode":null}""");

        Assert.NotNull(message);
        Assert.Equal(AudioCaptureMode.LowLatency, message.CaptureMode);
    }

    [Fact]
    public void RejectsMalformedJson()
    {
        Assert.Null(AudioControlMessage.Parse("{not-json"));
    }

    [Fact]
    public void RejectsOtherMessageType()
    {
        Assert.Null(AudioControlMessage.Parse(
            """{"type":"keyboard","enabled":true,"mode":"stable"}"""));
    }
}
