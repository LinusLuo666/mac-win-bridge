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
    using var client = await listener.AcceptTcpClientAsync();
    Console.WriteLine($"client connected from {client.Client.RemoteEndPoint}");

    using var stream = client.GetStream();
    using var reader = new StreamReader(stream);

    while (await reader.ReadLineAsync() is { } line)
    {
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

        if (message.Event == "flagsChanged")
        {
            Console.WriteLine($"flagsChanged sequence={message.Sequence}");
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

    Console.WriteLine("client disconnected");
}
