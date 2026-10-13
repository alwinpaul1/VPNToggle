using System;
using System.IO;

namespace VPNToggle;

/// A Start menu entry, so the app can be found by searching "VPNToggle" after Quit.
public static class Shortcuts
{
    public static void EnsureStartMenu()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (exe == null) return;
            var dir = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            var link = Path.Combine(dir, "VPNToggle.lnk");
            // WScript.Shell builds .lnk files without any extra package.
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null) return;
            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic shortcut = shell.CreateShortcut(link);
            if (File.Exists(link) && string.Equals((string)shortcut.TargetPath, exe, StringComparison.OrdinalIgnoreCase)) return;
            shortcut.TargetPath = exe;
            shortcut.WorkingDirectory = Path.GetDirectoryName(exe);
            shortcut.Description = "One-click Cisco VPN toggle";
            shortcut.IconLocation = exe + ",0";
            shortcut.Save();
        }
        catch { }
    }
}
