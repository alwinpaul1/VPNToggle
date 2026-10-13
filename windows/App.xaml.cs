using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;

namespace VPNToggle;

public partial class App : Application
{
    const string PipeName = "VPNToggle-commands";
    Mutex? single;
    AppController? controller;

    /// "connect" from `--connect` or `vpntoggle://connect`; null when started plainly.
    static string? CommandFrom(string[] args)
    {
        foreach (var a in args)
        {
            var s = a.Trim().ToLowerInvariant();
            if (s.StartsWith("vpntoggle://")) return s["vpntoggle://".Length..].Trim('/');
            if (s.StartsWith("--")) return s[2..];
        }
        return null;
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var command = CommandFrom(e.Args);
        // Started by Windows at sign-in: stay quietly in the tray. Started by hand: show the card,
        // so it is obvious the app is running (its tray icon may sit in the hidden ^ overflow).
        var quiet = command == "startup";
        if (quiet) command = null;

        // One copy only; a second launch hands its command to the running copy and exits.
        single = new Mutex(true, @"Local\VPNToggle", out var first);
        if (!first)
        {
            // Already running: a plain second launch brings up the card instead of doing nothing.
            command ??= "show";
            {
                try
                {
                    using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
                    client.Connect(2000);
                    using var w = new StreamWriter(client);
                    w.WriteLine(command);
                }
                catch { }
            }
            Shutdown();
            return;
        }

        RegisterUrlScheme();
        Shortcuts.EnsureStartMenu();
        Theme.Apply();
        Theme.Watch();
        controller = new AppController();
        ListenForCommands();
        if (command != null) controller.Handle(command);
        else if (!quiet) controller.FirstShow();
    }

    void ListenForCommands()
    {
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    using var server = new NamedPipeServerStream(PipeName, PipeDirection.In);
                    await server.WaitForConnectionAsync();
                    using var r = new StreamReader(server);
                    var line = (await r.ReadLineAsync())?.Trim();
                    if (!string.IsNullOrEmpty(line)) await Dispatcher.InvokeAsync(() => controller?.Handle(line));
                }
                catch { await Task.Delay(1000); }
            }
        });
    }

    /// vpntoggle:// links (for shortcuts, scripts, Stream Deck...) point at this exe; refreshed on every start.
    static void RegisterUrlScheme()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\vpntoggle");
            key.SetValue("", "URL:VPNToggle");
            key.SetValue("URL Protocol", "");
            using var cmd = key.CreateSubKey(@"shell\open\command");
            cmd.SetValue("", $"\"{Environment.ProcessPath}\" \"%1\"");
        }
        catch { }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        controller?.Dispose();
        single?.Dispose();
        base.OnExit(e);
    }
}
