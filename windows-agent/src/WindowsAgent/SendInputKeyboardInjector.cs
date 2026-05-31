using System.ComponentModel;
using System.Runtime.InteropServices;

namespace WindowsAgent;

public sealed class SendInputKeyboardInjector
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;

    public void Inject(KeyboardMessage message)
    {
        if (!WindowsKeyMapper.TryMap(message.Key, out var virtualKey))
        {
            Console.WriteLine($"unsupported key={message.Key} sequence={message.Sequence}");
            return;
        }

        var inputs = BuildInputs(message, virtualKey);
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != (uint)inputs.Length)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static Input[] BuildInputs(KeyboardMessage message, ushort virtualKey)
    {
        var modifierKeys = message.Modifiers
            .Select(TryMapModifier)
            .Where(static key => key.HasValue)
            .Select(static key => key!.Value)
            .ToArray();

        var inputs = new List<Input>();
        if (message.Event == "down")
        {
            inputs.AddRange(modifierKeys.Select(static key => KeyboardInput(key, 0)));
            inputs.Add(KeyboardInput(virtualKey, 0));
        }
        else
        {
            inputs.Add(KeyboardInput(virtualKey, KeyEventKeyUp));
            inputs.AddRange(modifierKeys.Reverse().Select(static key => KeyboardInput(key, KeyEventKeyUp)));
        }

        return inputs.ToArray();
    }

    private static ushort? TryMapModifier(string modifier)
    {
        return modifier switch
        {
            "shift" => 0x10,
            "control" => 0x11,
            "option" => 0x12,
            "command" => 0x5B,
            _ => null
        };
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

    [StructLayout(LayoutKind.Explicit)]
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
