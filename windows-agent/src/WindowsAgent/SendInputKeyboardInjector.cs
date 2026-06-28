using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WindowsAgent;

public sealed class SendInputKeyboardInjector
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private readonly KeyboardInputPlanner planner = new();

    public void Inject(KeyboardMessage message)
    {
        Send(planner.Plan(message));
    }

    public void ReleaseAllModifiers()
    {
        Send(planner.ReleaseAllModifiers());
    }

    private static void Send(IReadOnlyList<KeyboardStroke> strokes)
    {
        if (strokes.Count == 0)
        {
            return;
        }

        var inputs = strokes
            .Select(static stroke => KeyboardInput(
                stroke.VirtualKey,
                stroke.Kind == KeyboardStrokeKind.Up ? KeyEventKeyUp : 0))
            .ToArray();

        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != (uint)inputs.Length)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static Input KeyboardInput(ushort virtualKey, uint flags)
    {
        return new Input
        {
            Type = InputKeyboard,
            Data = new InputUnion
            {
                Keyboard = new KeyboardInputData
                {
                    VirtualKey = virtualKey,
                    ScanCode = 0,
                    Flags = flags,
                    Time = 0,
                    ExtraInfo = UIntPtr.Zero
                }
            }
        };
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInputData Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputData
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }
}
