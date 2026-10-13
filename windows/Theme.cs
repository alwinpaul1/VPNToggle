using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace VPNToggle;

/// Light/dark follows the Windows setting (Settings → Personalization → Colors) and switches live.
public static class Theme
{
    public static bool AppsUseLight => ReadPersonalize("AppsUseLightTheme", 1) != 0;
    public static bool TaskbarUsesLight => ReadPersonalize("SystemUsesLightTheme", 0) != 0;

    static int ReadPersonalize(string name, int fallback)
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue(name) is int v ? v : fallback;
    }

    public static event Action? Changed;

    public static void Apply()
    {
        var dicts = Application.Current.Resources.MergedDictionaries;
        dicts[0] = new ResourceDictionary { Source = new Uri(AppsUseLight ? "Themes/Light.xaml" : "Themes/Dark.xaml", UriKind.Relative) };
        Changed?.Invoke();
    }

    public static void Watch()
    {
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General)
                Application.Current.Dispatcher.BeginInvoke(Apply);
        };
    }

    // --- Windows 11 window chrome: rounded corners, acrylic backdrop, dark title colours ---

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    struct Margins { public int Left, Right, Top, Bottom; }

    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    const int DWMWA_SYSTEMBACKDROP_TYPE = 38;

    /// Acrylic needs Windows 11 22H2 (build 22621); older systems get a solid themed surface.
    public static bool SupportsBackdrop => Environment.OSVersion.Version.Build >= 22621;

    public static void StyleWindow(Window w, bool acrylic)
    {
        var hwnd = new WindowInteropHelper(w).EnsureHandle();
        var dark = AppsUseLight ? 0 : 1;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
        var round = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));

        if (SupportsBackdrop)
        {
            var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            DwmExtendFrameIntoClientArea(hwnd, ref margins);
            var backdrop = acrylic ? 3 : 2; // 3 = acrylic (transient), 2 = Mica
            DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
            w.Background = Brushes.Transparent;
            if (HwndSource.FromHwnd(hwnd) is { } src) src.CompositionTarget.BackgroundColor = Colors.Transparent;
        }
        else
        {
            w.SetResourceReference(Window.BackgroundProperty, "SurfaceFallback");
        }
    }
}
