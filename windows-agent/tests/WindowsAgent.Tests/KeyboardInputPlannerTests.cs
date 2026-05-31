using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class KeyboardInputPlannerTests
{
    [Fact]
    public void ReleasesModifiersThatAreNoLongerActive()
    {
        var planner = new KeyboardInputPlanner();

        Assert.Equal(
            new[] { new KeyboardStroke(0x11, KeyboardStrokeKind.Down) },
            planner.Plan(new KeyboardMessage("key", "flagsChanged", "Control", new[] { "control" }, 1)));

        Assert.Equal(
            new[] { new KeyboardStroke(0x11, KeyboardStrokeKind.Up) },
            planner.Plan(new KeyboardMessage("key", "flagsChanged", "Control", Array.Empty<string>(), 2)));
    }

    [Fact]
    public void ReleasesAllModifiersWhenConnectionCloses()
    {
        var planner = new KeyboardInputPlanner();
        planner.Plan(new KeyboardMessage("key", "flagsChanged", "Shift", new[] { "shift", "control" }, 1));

        Assert.Equal(
            new[]
            {
                new KeyboardStroke(0x11, KeyboardStrokeKind.Up),
                new KeyboardStroke(0x10, KeyboardStrokeKind.Up)
            },
            planner.ReleaseAllModifiers());
    }

    [Fact]
    public void DoesNotMapCommandToWindowsKeyInM0()
    {
        var planner = new KeyboardInputPlanner();

        Assert.Empty(
            planner.Plan(new KeyboardMessage("key", "flagsChanged", "Command", new[] { "command" }, 1)));
    }
}
