using System.Net.Sockets;

namespace WindowsAgent;

public static class ClientSessionGuard
{
    public static async Task RunAsync(
        Func<Task> runSession,
        Func<Task> cleanup,
        Action<string> log)
    {
        try
        {
            await runSession();
        }
        catch (OperationCanceledException ex)
        {
            log($"client transport closed: {Describe(ex)}");
        }
        catch (IOException ex)
        {
            log($"client transport closed: {Describe(ex)}");
        }
        catch (SocketException ex)
        {
            log($"client transport closed: {Describe(ex)}");
        }
        finally
        {
            await cleanup();
        }
    }

    private static string Describe(Exception exception)
    {
        var socketException = exception as SocketException
            ?? exception.InnerException as SocketException;
        return socketException is null
            ? exception.Message
            : $"{exception.Message} socketError={socketException.SocketErrorCode} nativeError={socketException.ErrorCode}";
    }
}
