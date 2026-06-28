using System.Runtime.InteropServices;

namespace WindowsAgent;

public sealed class WasapiLoopbackAudioStreamer
{
    private static readonly Guid MMDeviceEnumeratorId = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid AudioClientId = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    private static readonly Guid AudioCaptureClientId = new("C8ADBD64-E71E-48a0-A4DE-185C395CD317");

    public void Stream(AudioFrameWriter writer, CancellationToken cancellationToken)
    {
        var initializedCom = false;
        object? audioClientObject = null;
        object? captureClientObject = null;
        IMMDevice? device = null;
        IAudioClient? audioClient = null;
        IAudioCaptureClient? captureClient = null;
        IntPtr mixFormatPtr = IntPtr.Zero;

        try
        {
            var coInitializeResult = CoInitializeEx(IntPtr.Zero, CoInit.MultiThreaded);
            initializedCom = coInitializeResult is HResult.Ok or HResult.False;
            if (!initializedCom && coInitializeResult != HResult.ChangedMode)
            {
                Marshal.ThrowExceptionForHR(coInitializeResult);
            }

            var enumeratorType = Type.GetTypeFromCLSID(MMDeviceEnumeratorId, throwOnError: true)
                ?? throw new InvalidOperationException("Failed to create WASAPI device enumerator type.");
            var enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(enumeratorType)!;
            ThrowIfFailed(enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Console, out device));
            var audioClientId = AudioClientId;
            ThrowIfFailed(device.Activate(ref audioClientId, ClsCtx.All, IntPtr.Zero, out audioClientObject));

            audioClient = (IAudioClient?)audioClientObject
                ?? throw new InvalidOperationException("Failed to activate WASAPI audio client.");
            ThrowIfFailed(audioClient.GetMixFormat(out mixFormatPtr));
            var format = ReadAudioFormat(mixFormatPtr);

            const long bufferDuration = 10_000_000;
            var audioSessionId = Guid.Empty;
            ThrowIfFailed(audioClient.Initialize(
                AudioClientShareMode.Shared,
                AudioClientStreamFlags.Loopback,
                bufferDuration,
                0,
                mixFormatPtr,
                ref audioSessionId));
            var audioCaptureClientId = AudioCaptureClientId;
            ThrowIfFailed(audioClient.GetService(ref audioCaptureClientId, out captureClientObject));

            captureClient = (IAudioCaptureClient?)captureClientObject
                ?? throw new InvalidOperationException("Failed to activate WASAPI capture client.");
            ThrowIfFailed(audioClient.Start());

            try
            {
                CaptureLoop(captureClient, format, writer, cancellationToken);
            }
            finally
            {
                audioClient.Stop();
            }
        }
        finally
        {
            if (mixFormatPtr != IntPtr.Zero)
            {
                Marshal.FreeCoTaskMem(mixFormatPtr);
            }

            ReleaseComObject(captureClientObject);
            ReleaseComObject(audioClientObject);
            ReleaseComObject(device);

            if (initializedCom)
            {
                CoUninitialize();
            }
        }
    }

    private static void CaptureLoop(
        IAudioCaptureClient captureClient,
        AudioFormat format,
        AudioFrameWriter writer,
        CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            ThrowIfFailed(captureClient.GetNextPacketSize(out var packetFrames));
            if (packetFrames == 0)
            {
                cancellationToken.WaitHandle.WaitOne(TimeSpan.FromMilliseconds(5));
                continue;
            }

            while (packetFrames > 0 && !cancellationToken.IsCancellationRequested)
            {
                ThrowIfFailed(captureClient.GetBuffer(
                    out var data,
                    out var framesAvailable,
                    out var flags,
                    out _,
                    out var qpcPosition));

                try
                {
                    var byteCount = checked((int)(framesAvailable * format.BlockAlign));
                    var pcm = new byte[byteCount];
                    if (!flags.HasFlag(AudioClientBufferFlags.Silent) && data != IntPtr.Zero)
                    {
                        Marshal.Copy(data, pcm, 0, pcm.Length);
                    }

                    writer.Write(new AudioFrame(format, checked((int)framesAvailable), qpcPosition, pcm));
                }
                finally
                {
                    ThrowIfFailed(captureClient.ReleaseBuffer(framesAvailable));
                }

                ThrowIfFailed(captureClient.GetNextPacketSize(out packetFrames));
            }
        }
    }

    private static AudioFormat ReadAudioFormat(IntPtr mixFormatPtr)
    {
        var waveFormat = Marshal.PtrToStructure<WaveFormatEx>(mixFormatPtr);
        if (waveFormat.Channels == 0 || waveFormat.BlockAlign == 0)
        {
            throw new InvalidOperationException("Default render device returned an invalid audio format.");
        }

        return new AudioFormat(
            checked((int)waveFormat.SamplesPerSecond),
            waveFormat.Channels,
            waveFormat.BitsPerSample,
            waveFormat.FormatTag,
            waveFormat.BlockAlign);
    }

    private static void ThrowIfFailed(int hresult)
    {
        if (hresult < 0)
        {
            Marshal.ThrowExceptionForHR(hresult);
        }
    }

    private static void ReleaseComObject(object? instance)
    {
        if (instance is not null && Marshal.IsComObject(instance))
        {
            Marshal.ReleaseComObject(instance);
        }
    }

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, CoInit coInit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    private static class HResult
    {
        public const int Ok = 0;
        public const int False = 1;
        public const int ChangedMode = unchecked((int)0x80010106);
    }

    [Flags]
    private enum CoInit : uint
    {
        MultiThreaded = 0x0
    }

    private enum EDataFlow
    {
        Render,
        Capture,
        All
    }

    private enum ERole
    {
        Console,
        Multimedia,
        Communications
    }

    [Flags]
    private enum ClsCtx : uint
    {
        InprocServer = 0x1,
        InprocHandler = 0x2,
        LocalServer = 0x4,
        RemoteServer = 0x10,
        All = InprocServer | InprocHandler | LocalServer | RemoteServer
    }

    private enum AudioClientShareMode
    {
        Shared,
        Exclusive
    }

    [Flags]
    private enum AudioClientStreamFlags : uint
    {
        Loopback = 0x00020000
    }

    [Flags]
    private enum AudioClientBufferFlags : uint
    {
        None = 0x0,
        DataDiscontinuity = 0x1,
        Silent = 0x2,
        TimestampError = 0x4
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormatEx
    {
        public ushort FormatTag;
        public ushort Channels;
        public uint SamplesPerSecond;
        public uint AverageBytesPerSecond;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);

        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(
            ref Guid interfaceId,
            ClsCtx classContext,
            IntPtr activationParameters,
            [MarshalAs(UnmanagedType.IUnknown)] out object audioInterface);

        int OpenPropertyStore(uint accessMode, out IntPtr properties);

        int GetId(out IntPtr id);

        int GetState(out uint state);
    }

    [ComImport]
    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        int Initialize(
            AudioClientShareMode shareMode,
            AudioClientStreamFlags streamFlags,
            long bufferDuration,
            long periodicity,
            IntPtr format,
            ref Guid audioSessionGuid);

        int GetBufferSize(out uint bufferSize);

        int GetStreamLatency(out long latency);

        int GetCurrentPadding(out uint currentPadding);

        int IsFormatSupported(
            AudioClientShareMode shareMode,
            IntPtr format,
            out IntPtr closestMatch);

        int GetMixFormat(out IntPtr deviceFormat);

        int GetDevicePeriod(out long defaultDevicePeriod, out long minimumDevicePeriod);

        int Start();

        int Stop();

        int Reset();

        int SetEventHandle(IntPtr eventHandle);

        int GetService(ref Guid interfaceId, [MarshalAs(UnmanagedType.IUnknown)] out object serviceInterface);
    }

    [ComImport]
    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        int GetBuffer(
            out IntPtr data,
            out uint framesAvailable,
            out AudioClientBufferFlags flags,
            out ulong devicePosition,
            out ulong qpcPosition);

        int ReleaseBuffer(uint framesRead);

        int GetNextPacketSize(out uint packetSize);
    }
}
