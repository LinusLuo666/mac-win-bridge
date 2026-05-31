using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class KeyboardMessageTests
{
    [Fact]
    public void ParsesValidKeyMessage()
    {
        var message = KeyboardMessage.Parse("""{"type":"key","event":"down","key":"KeyA","modifiers":["shift"],"sequence":42}""");

        Assert.NotNull(message);
        Assert.Equal("down", message.Event);
        Assert.Equal("KeyA", message.Key);
        Assert.Equal(new[] { "shift" }, message.Modifiers);
        Assert.Equal(42, message.Sequence);
    }

    [Fact]
    public void RejectsMalformedJson()
    {
        Assert.Null(KeyboardMessage.Parse("{not-json"));
    }

    [Fact]
    public void RejectsUnknownMessageType()
    {
        Assert.Null(KeyboardMessage.Parse("""{"type":"mouse","event":"down","key":"KeyA","modifiers":[],"sequence":1}"""));
    }
}
