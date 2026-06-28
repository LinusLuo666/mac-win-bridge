using System.Buffers.Binary;
using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class AudioFrameWriterTests
{
    [Fact]
    public void WritesAudioFrameHeaderMetadataAndPcm()
    {
        using var stream = new MemoryStream();
        var writer = new AudioFrameWriter(stream);
        var format = new AudioFormat(48_000, 2, 32, 3, 8);

        writer.Write(new AudioFrame(format, 2, 1234, new byte[] { 1, 2, 3, 4 }));

        var bytes = stream.ToArray();
        Assert.Equal(ProtocolMessageType.AudioFrame, bytes[0]);
        Assert.Equal(28, BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(1, 4)));

        var payload = bytes.AsSpan(5);
        Assert.Equal(48_000, BinaryPrimitives.ReadInt32LittleEndian(payload[0..4]));
        Assert.Equal(2, BinaryPrimitives.ReadUInt16LittleEndian(payload[4..6]));
        Assert.Equal(32, BinaryPrimitives.ReadUInt16LittleEndian(payload[6..8]));
        Assert.Equal(3, BinaryPrimitives.ReadUInt16LittleEndian(payload[8..10]));
        Assert.Equal(8, BinaryPrimitives.ReadUInt16LittleEndian(payload[10..12]));
        Assert.Equal(2, BinaryPrimitives.ReadInt32LittleEndian(payload[12..16]));
        Assert.Equal((ulong)1234, BinaryPrimitives.ReadUInt64LittleEndian(payload[16..24]));
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, payload[24..].ToArray());
    }
}
