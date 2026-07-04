using System.Runtime.InteropServices;

namespace WindowsAgent;

public static class AudioDeviceRecovery
{
    public const int DeviceInvalidatedHResult = unchecked((int)0x88890004);

    public static void Run(
        Action streamOnce,
        CancellationToken cancellationToken,
        Action<string> log,
        TimeSpan? retryDelay = null)
    {
        var delay = retryDelay ?? TimeSpan.FromSeconds(1);

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                streamOnce();
                return;
            }
            catch (COMException ex) when (ex.HResult == DeviceInvalidatedHResult)
            {
                log($"audio endpoint invalidated hresult=0x{ex.HResult:X8}; reacquiring default endpoint");
                if (cancellationToken.WaitHandle.WaitOne(delay))
                {
                    return;
                }
            }
        }
    }
}
