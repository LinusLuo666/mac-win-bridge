namespace WindowsAgent;

public sealed record AudioFormat(
    int SampleRate,
    ushort Channels,
    ushort BitsPerSample,
    ushort FormatTag,
    ushort BlockAlign);

public sealed record AudioFrame(
    AudioFormat Format,
    int FrameCount,
    ulong QpcPosition,
    ReadOnlyMemory<byte> Pcm);
