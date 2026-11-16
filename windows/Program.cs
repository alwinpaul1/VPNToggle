using System;

namespace VPNToggle;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (NvmPause.RunMode(args) is { } code) return code;
        if (SelfUpdate.RunNoticeTestMode(args) is { } noticed) return noticed;
        if (SelfUpdate.RunTestMode(args) is { } result) return result;
        App.Main();
        return 0;
    }
}
