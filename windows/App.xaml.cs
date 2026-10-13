using System.Threading;
using System.Windows;

namespace VPNToggle;

public partial class App : Application
{
    Mutex? single;
    AppController? controller;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // One copy only; a second launch just exits.
        single = new Mutex(true, @"Local\VPNToggle", out var first);
        if (!first) { Shutdown(); return; }

        Theme.Apply();
        Theme.Watch();
        controller = new AppController();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        controller?.Dispose();
        single?.Dispose();
        base.OnExit(e);
    }
}
