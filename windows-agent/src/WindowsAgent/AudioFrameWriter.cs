using System.Buffers.Binary;

namespace WindowsAgent;

public sealed class AudioFrameWriter
{
    private const int FrameHeaderLength = 5;
    private const int MetadataLength = 24;
    private readonly object writeLock = new();
    private readonly Stream stream;

    public AudioFrameWriter(Stream stream)
    {
        this.stream = stream;
    }

    public void Write(AudioFrame frame)
    {
        if (frame.FrameCount < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(frame), "Frame count cannot be negative.");
        }

        var payloadLength = MetadataLength + frame.Pcm.Length;
        Span<byte> header = stackalloc byte[FrameHeaderLength];
        header[0] = ProtocolMessageType.AudioFrame;
        BinaryPrimitives.WriteInt32LittleEndian(header[1..], payloadLength);

        Span<byte> metadata = stackalloc byte[MetadataLength];
        BinaryPrimitives.WriteInt32LittleEndian(metadata[0..], frame.Format.SampleRate);
        BinaryPrimitives.WriteUInt16LittleEndian(metadata[4..], frame.Format.Channels);
        BinaryPrimitives.WriteUInt16LittleEndian(metadata[6..], frame.Format.BitsPerSample);
        BinaryPrimitives.WriteUInt16LittleEndian(metadata[8..], frame.Format.FormatTag);
        BinaryPrimitives.WriteUInt16LittleEndian(metadata[10..], frame.Format.BlockAlign);
        BinaryPrimitives.WriteInt32LittleEndian(metadata[12..], frame.FrameCount);
        BinaryPrimitives.WriteUInt64LittleEndian(metadata[16..], frame.QpcPosition);

        lock (writeLock)
        {
            stream.Write(header);
            stream.Write(metadata);
            stream.Write(frame.Pcm.Span);
            stream.Flush();
        }
    }
}
