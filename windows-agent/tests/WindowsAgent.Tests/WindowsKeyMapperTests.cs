using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class WindowsKeyMapperTests
{
    [Theory]
    [InlineData("KeyA", 0x41)]
    [InlineData("Digit1", 0x31)]
    [InlineData("Enter", 0x0D)]
    [InlineData("Tab", 0x09)]
    [InlineData("Space", 0x20)]
    [InlineData("Backspace", 0x08)]
    [InlineData("Escape", 0x1B)]
    [InlineData("ArrowLeft", 0x25)]
    [InlineData("ArrowRight", 0x27)]
    [InlineData("ArrowDown", 0x28)]
    [InlineData("ArrowUp", 0x26)]
    public void MapsStableKeysToVirtualKeys(string stableKey, ushort expectedVirtualKey)
    {
        Assert.True(WindowsKeyMapper.TryMap(stableKey, out var virtualKey));
        Assert.Equal(expectedVirtualKey, virtualKey);
    }

    [Fact]
    public void RejectsUnknownStableKey()
    {
        Assert.False(WindowsKeyMapper.TryMap("UnknownKey", out _));
    }
}
