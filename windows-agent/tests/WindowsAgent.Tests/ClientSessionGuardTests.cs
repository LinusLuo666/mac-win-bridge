using System.Net.Sockets;
using WindowsAgent;
using Xunit;

namespace WindowsAgent.Tests;

public sealed class ClientSessionGuardTests
{
    [Fact]
    public async Task TreatsConnectionResetIOExceptionAsClientSessionEnd()
    {
        var logs = new List<string>();
        var cleanupCalls = 0;
        var reset = new IOException(
            "Unable to read data from the transport connection.",
            new SocketException(10054));

        await ClientSessionGuard.RunAsync(
            () => Task.FromException(reset),
            () =>
            {
                cleanupCalls++;
                return Task.CompletedTask;
            },
            logs.Add);

        Assert.Equal(1, cleanupCalls);
        Assert.Contains(logs, log =>
            log.Contains("client transport closed", StringComparison.Ordinal)
            && log.Contains("10054", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TreatsSocketExceptionAsClientSessionEnd()
    {
        var logs = new List<string>();
        var cleanupCalls = 0;

        await ClientSessionGuard.RunAsync(
            () => Task.FromException(new SocketException(10054)),
            () =>
            {
                cleanupCalls++;
                return Task.CompletedTask;
            },
            logs.Add);

        Assert.Equal(1, cleanupCalls);
        Assert.Contains(logs, log => log.Contains("client transport closed", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TreatsCancellationAsClientSessionEnd()
    {
        var logs = new List<string>();
        var cleanupCalls = 0;

        await ClientSessionGuard.RunAsync(
            () => Task.FromException(new OperationCanceledException("client canceled")),
            () =>
            {
                cleanupCalls++;
                return Task.CompletedTask;
            },
            logs.Add);

        Assert.Equal(1, cleanupCalls);
        Assert.Contains(logs, log => log.Contains("client transport closed", StringComparison.Ordinal));
    }
}
