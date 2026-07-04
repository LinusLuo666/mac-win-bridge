using System.Runtime.InteropServices;
using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class AudioDeviceRecoveryTests
{
    [Fact]
    public void ReacquiresEndpointAfterDeviceInvalidation()
    {
        var attempts = 0;
        var logs = new List<string>();

        AudioDeviceRecovery.Run(
            () =>
            {
                attempts++;
                if (attempts == 1)
                {
                    throw new COMException(
                        "device invalidated",
                        AudioDeviceRecovery.DeviceInvalidatedHResult);
                }
            },
            CancellationToken.None,
            logs.Add,
            TimeSpan.Zero);

        Assert.Equal(2, attempts);
        Assert.Contains(logs, log =>
            log.Contains("audio endpoint invalidated", StringComparison.Ordinal)
            && log.Contains("0x88890004", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void DoesNotRetryUnrelatedComFailure()
    {
        var attempts = 0;

        var exception = Assert.Throws<COMException>(() =>
            AudioDeviceRecovery.Run(
                () =>
                {
                    attempts++;
                    throw new COMException("unrelated", unchecked((int)0x80004005));
                },
                CancellationToken.None,
                _ => { },
                TimeSpan.Zero));

        Assert.Equal(unchecked((int)0x80004005), exception.HResult);
        Assert.Equal(1, attempts);
    }

    [Fact]
    public void CancellationStopsDeviceRecoveryRetries()
    {
        using var cancellation = new CancellationTokenSource();
        var attempts = 0;

        AudioDeviceRecovery.Run(
            () =>
            {
                attempts++;
                cancellation.Cancel();
                throw new COMException(
                    "device invalidated",
                    AudioDeviceRecovery.DeviceInvalidatedHResult);
            },
            cancellation.Token,
            _ => { },
            TimeSpan.Zero);

        Assert.Equal(1, attempts);
    }
}
