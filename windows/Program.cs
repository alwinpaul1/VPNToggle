using System;

namespace VPNToggle;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (NvmPause.RunMode(args) is { } code) return code;
        App.Main();
        return 0;
    }
}
