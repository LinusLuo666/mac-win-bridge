using System.Net;
using System.Net.Sockets;
using WindowsAgent;

var port = args.Length > 0 && int.TryParse(args[0], out var parsedPort) ? parsedPort : 5055;
var listener = new TcpListener(IPAddress.Any, port);
var injector = new SendInputKeyboardInjector();

listener.Start();
Console.WriteLine($"WindowsAgent listening on port {port}");

while (true)
{
    Console.WriteLine("waiting for next client");
    using var client = await listener.AcceptTcpClientAsync();
    Console.WriteLine($"client connected from {client.Client.RemoteEndPoint}");

    using var stream = client.GetStream();
    using var reader = new StreamReader(stream);
    var audioWriter = new AudioFrameWriter(stream);
    CancellationTokenSource? audioCancellation = null;
    Task? audioTask = null;

    async Task StopAudioAsync()
    {
        if (audioCancellation is null)
        {
            return;
        }

        audioCancellation.Cancel();
        if (audioTask is not null)
        {
            try
            {
                await audioTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        audioCancellation.Dispose();
        audioCancellation = null;
        audioTask = null;
        Console.WriteLine("audio loopback stopped");
    }

    void StartAudio(AudioCaptureMode captureMode)
    {
        StopAudioAsync().GetAwaiter().GetResult();
        audioCancellation = new CancellationTokenSource();
        var cancellationToken = audioCancellation.Token;
        audioTask = Task.Run(() =>
        {
            try
            {
                new WasapiLoopbackAudioStreamer().Stream(audioWriter, cancellationToken);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                Console.WriteLine($"audio loopback failed mode={captureMode}: {ex}");
            }
        }, cancellationToken);
        Console.WriteLine($"audio loopback starting mode={captureMode}");
    }

    async Task RunClientAsync()
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            var audioControl = AudioControlMessage.Parse(line);
            if (audioControl is not null)
            {
                if (audioControl.Enabled)
                {
                    StartAudio(audioControl.CaptureMode);
                }
                else
                {
                    await StopAudioAsync();
                }

                continue;
            }

            var message = KeyboardMessage.Parse(line);
            if (message is null)
            {
                Console.WriteLine($"rejected message: {line}");
                continue;
            }

            if (message.Event is not ("down" or "up" or "flagsChanged"))
            {
                Console.WriteLine($"ignored event={message.Event} sequence={message.Sequence}");
                continue;
            }

            try
            {
                injector.Inject(message);
                Console.WriteLine($"injected sequence={message.Sequence} event={message.Event} key={message.Key}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"injection failed sequence={message.Sequence}: {ex.Message}");
            }
        }
    }

    async Task CleanupClientAsync()
    {
        try
        {
            await StopAudioAsync();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"audio cleanup failed: {ex}");
        }

        try
        {
            injector.ReleaseAllModifiers();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"modifier release failed: {ex.Message}");
        }

        client.Close();
        Console.WriteLine("client disconnected");
    }

    await ClientSessionGuard.RunAsync(
        RunClientAsync,
        CleanupClientAsync,
        Console.WriteLine);
}
