using System.Reflection;
using System.Runtime.InteropServices;
using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class SendInputKeyboardInjectorTests
{
    [Fact]
    public void InputStructureMatchesNativeWindowsSize()
    {
        var inputType = typeof(SendInputKeyboardInjector).GetNestedType("Input", BindingFlags.NonPublic);

        Assert.NotNull(inputType);
        Assert.Equal(40, Marshal.SizeOf(inputType));
    }

}
