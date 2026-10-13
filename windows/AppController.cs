using System;
using System.Drawing;
using System.Linq;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Windows.Threading;
using Microsoft.Win32;
using Brush = System.Windows.Media.Brush;
using MediaColor = System.Windows.Media.Color;
using SolidBrush = System.Drawing.SolidBrush;
using WpfBrush = System.Windows.Media.SolidColorBrush;

namespace VPNToggle;

/// The tray icon and all VPN logic: state polling, connect/disconnect, auto-reconnect, notifications.
public sealed class AppController : IDisposable
{
    readonly NotifyIcon tray = new();
    readonly CardViewModel vm = new();
    readonly CardWindow card;
    readonly HoverWindow hover;
    readonly Settings settings = Settings.Load();
    readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(3) };

    VpnState state = VpnState.Unknown;
    /// The tunnel's address while connected; polling just checks it is still on an interface.
    string? ip;
    DateTime? connectedSince;
    System.Collections.Generic.HashSet<string> lastTunnels = new();
    DateTime nextSlowCheck = DateTime.MinValue;
    string? Duration => connectedSince is { } t ? Cisco.FormatDuration((int)(DateTime.Now - t).TotalSeconds) : null;
    bool working;
    string? activity;
    /// True from a successful connect until the user disconnects; a drop in between triggers a reconnect.
    bool wantConnected;
    int reconnectAttempts;
    DispatcherTimer? reconnectTimer;

    static readonly TimeSpan[] ReconnectDelays =
        { TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(2), TimeSpan.FromMinutes(5) };

    static readonly Color Green = Color.FromArgb(0x22, 0xC5, 0x5E);
    static readonly Color Orange = Color.FromArgb(0xF5, 0x9E, 0x0B);
    static readonly Color Blue = Color.FromArgb(0x25, 0x63, 0xEB);
    static readonly Color Gray = Color.FromArgb(0x8A, 0x8A, 0x8A);

    public AppController()
    {
        card = new CardWindow(vm);
        hover = new HoverWindow(vm);
        card.ToggleRequested += Toggle;
        card.CredentialsRequested += EditCredentials;
        card.QuitRequested += Quit;
        card.LaunchAtLogin = () => Startup.Enabled;
        card.SetLaunchAtLogin = on => Startup.Enabled = on;
        card.CurrentIp = () => state == VpnState.Connected ? ip : null;
        vm.AutoReconnectChanged += on =>
        {
            settings.AutoReconnect = on;
            settings.Save();
            Log.Write($"auto-reconnect {(on ? "on" : "off")}");
            if (!on) CancelReconnect();
        };

        tray.Visible = true;
        // The hover card stands in for the tray tooltip, so the plain tooltip stays empty.
        tray.Text = "";
        tray.MouseMove += (_, _) => hover.PointerOverIcon(() => card.IsVisible);
        tray.MouseUp += (_, e) =>
        {
            if (e.Button != MouseButtons.Left) return;
            hover.HidePeek();
            // A click on the icon first deactivates (hides) an open card; do not reopen it straight away.
            if (card.IsVisible || (DateTime.Now - card.HiddenAt).TotalMilliseconds < 300) { card.HideCard(); return; }
            OpenCard();
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => OpenCard());
        menu.Items.Add("Connect / Disconnect", null, (_, _) => Toggle());
        menu.Items.Add("Credentials…", null, (_, _) => EditCredentials());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Quit());
        tray.ContextMenuStrip = menu;

        Theme.Changed += Render;
        poll.Tick += (_, _) => Refresh();
        poll.Start();
        var tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        tick.Tick += (_, _) => { if (card.IsVisible) UpdateClock(); };
        tick.Start();
        // Cisco drops the tunnel on sleep; check soon after resume so a reconnect starts quickly.
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume)
                ui.BeginInvoke(async () => { await Task.Delay(8000); Refresh(force: true); });
        };

        Log.Write("app started");
        Render();
        Refresh();
        if (Cisco.Cli == null)
            Dialogs.Message("Cisco Secure Client not found", "Install Cisco Secure Client (or AnyConnect) first; VPNToggle drives its vpncli.exe.");
        else if (Secrets.Get("password") == null)
            EditCredentials();
    }

    /// vpntoggle://connect, disconnect, toggle, show (also --connect etc. on the command line).
    public void Handle(string command)
    {
        Log.Write($"command: {command}");
        switch (command)
        {
            case "connect" when state != VpnState.Connected:
            case "disconnect" when state == VpnState.Connected:
            case "toggle":
                Toggle();
                break;
            case "show":
                OpenCard(nearTray: true);
                break;
        }
    }

    /// A hand launch: open the card near the tray, and the first time explain where the app lives.
    public void FirstShow()
    {
        if (!settings.ShownTrayTip)
        {
            settings.ShownTrayTip = true;
            settings.Save();
            tray.ShowBalloonTip(8000, "VPNToggle is running",
                "It lives in the system tray by the clock. If you don't see the shield, click ^ and drag it onto the taskbar. " +
                "Find it again any time in the Start menu.", ToolTipIcon.Info);
        }
        if (Secrets.Get("password") != null) OpenCard(nearTray: true);
    }

    void OpenCard() => OpenCard(nearTray: false);

    void OpenCard(bool nearTray)
    {
        vm.TwoFactor = Secrets.Get("totp") != null ? "Automatic" : "Asks for code";
        vm.SetAutoReconnectSilently(settings.AutoReconnect);
        Refresh(force: ip == null);
        hover.HidePeek();
        card.ShowNearTray(nearTray ? null : System.Windows.Forms.Cursor.Position);
    }

    void EditCredentials()
    {
        if (Dialogs.EditCredentials(settings)) Render();
    }

    void Quit()
    {
        Log.Write("app quit");
        Dispose();
        System.Windows.Application.Current.Shutdown();
    }

    void Notify(string title, string body) => tray.ShowBalloonTip(5000, title, body, ToolTipIcon.None);

    // --- state ---

    /// Cheap check every 3 s: is the tunnel's address still up? Cisco's slow CLI runs only when the
    /// answer is unclear (tunnel gone, interfaces changed, nothing known yet) or every 15 s while off.
    void Refresh(bool force = false)
    {
        if (working) return;
        var tunnels = Cisco.TunnelAddresses();
        var changed = !tunnels.SetEquals(lastTunnels);
        lastTunnels = tunnels;
        if (ip != null && tunnels.Contains(ip)) { Apply(VpnState.Connected, null); return; }
        if (!(force || changed || ip != null || DateTime.Now >= nextSlowCheck)) return;
        nextSlowCheck = DateTime.Now.AddSeconds(15);
        Task.Run(() =>
        {
            if (working) return;   // a connect/disconnect started meanwhile; it reports the state itself
            var s = Cisco.State();
            (string? ip, int? seconds)? learned = s == VpnState.Connected && !working ? Cisco.Info() : null;
            ui.BeginInvoke(() => { if (!working) Apply(s, learned); });
        });
    }

    void Apply(VpnState s, (string? ip, int? seconds)? learned)
    {
        if (s != state && state != VpnState.Unknown) Log.Write($"state {state} -> {s}");
        if (state == VpnState.Connected && s == VpnState.Disconnected && wantConnected)
            Notify("VPN dropped", settings.AutoReconnect ? $"Reconnecting to {settings.Host}…" : "Click the tray icon to reconnect.");
        // A tunnel already up when the app starts (or made by the Cisco app) is kept up too.
        if (state == VpnState.Unknown && s == VpnState.Connected) wantConnected = true;
        if (learned is { } l)
        {
            ip = l.ip;
            connectedSince = l.seconds is { } sec ? DateTime.Now.AddSeconds(-sec) : connectedSince ?? DateTime.Now;
        }
        if (s != VpnState.Connected) { ip = null; connectedSince = null; }
        state = s;
        Render();
        if (s == VpnState.Disconnected && wantConnected && settings.AutoReconnect && reconnectTimer == null)
            ScheduleReconnect();
    }

    void Render()
    {
        var connected = state == VpnState.Connected && !working;
        var dropped = wantConnected && state != VpnState.Connected;
        Color color;
        string title, glyph;
        if (working) { color = Blue; title = activity ?? "Working…"; glyph = "\uE7E8"; }
        else if (connected) { color = Green; title = "Connected"; glyph = "\uE7E8"; }
        else if (dropped) { color = Orange; title = "Connection dropped"; glyph = "\uE7E8"; }
        else if (state == VpnState.Unknown) { color = Gray; title = "Checking…"; glyph = "\uE7E8"; }
        else { color = Gray; title = "Not connected"; glyph = "\uE7E8"; }

        vm.Host = settings.Host;
        vm.Title = title;
        vm.Glyph = glyph;
        vm.Tint = new WpfBrush(MediaColor.FromRgb(color.R, color.G, color.B));
        vm.Connected = connected;
        vm.Busy = working;
        vm.Ip = ip ?? "—";
        vm.Duration = Duration ?? "—";
        vm.ButtonText = connected ? "Turn the VPN off" : "Turn the VPN on";
        var lit = connected || (dropped && !working);
        var tintBrush = new WpfBrush(MediaColor.FromRgb(color.R, color.G, color.B));
        var secondary = (Brush)System.Windows.Application.Current.Resources["TextSecondary"];
        var primary = (Brush)System.Windows.Application.Current.Resources["TextPrimary"];
        vm.Lit = lit;
        vm.GlyphBrush = lit ? tintBrush : secondary;
        vm.TitleBrush = lit ? tintBrush : primary;
        vm.OutlineBrush = lit ? new WpfBrush(MediaColor.FromArgb(0x8C, color.R, color.G, color.B)) : System.Windows.Media.Brushes.Transparent;
        UpdateClock();
        vm.ButtonBrush = new WpfBrush(connected ? MediaColor.FromRgb(0xC4, 0x2B, 0x1C) : MediaColor.FromRgb(0x00, 0x67, 0xC0));

        vm.HoverTitle = connected ? "VPN connected" : title;
        vm.HoverDetail = connected ? $"{ip} · for {Duration}"
            : working ? "Please wait"
            : dropped ? (settings.AutoReconnect ? "Reconnecting automatically…" : "Reconnect when you are ready")
            : "Click for details";
        SetTrayIcon(working ? Blue : connected ? Green : dropped ? Orange : (Color?)null);
    }

    /// The live session timer under "Connected", ticking every second.
    void UpdateClock()
    {
        if (connectedSince is not { } t) { vm.Clock = ""; return; }
        var d = DateTime.Now - t;
        vm.Clock = $"{(int)d.TotalHours:00}:{d.Minutes:00}:{d.Seconds:00}";
    }

    // --- actions ---

    void Toggle()
    {
        if (working) return;
        if (state == VpnState.Connected) Disconnect(); else ConnectNow(auto: false);
    }

    void Disconnect()
    {
        Log.Write("disconnect requested by user");
        wantConnected = false;
        CancelReconnect();
        activity = "Disconnecting…";
        var tunnelIp = ip;
        Run(() => (true, null, "", Cisco.Disconnect(tunnelIp) ? VpnState.Disconnected : null, null));
    }

    void CancelReconnect()
    {
        reconnectTimer?.Stop();
        reconnectTimer = null;
        reconnectAttempts = 0;
    }

    /// Backs off 5 s, 30 s, 2 min, 5 min, then gives up and says so.
    void ScheduleReconnect()
    {
        if (reconnectAttempts >= ReconnectDelays.Length)
        {
            Log.Write($"auto-reconnect gave up after {reconnectAttempts} attempts");
            wantConnected = false;
            CancelReconnect();
            Render();
            Dialogs.Message("VPN disconnected", $"The VPN dropped and {ReconnectDelays.Length} reconnect attempts failed.");
            return;
        }
        var delay = ReconnectDelays[reconnectAttempts++];
        Log.Write($"dropped; reconnect attempt {reconnectAttempts} in {delay.TotalSeconds:0} s");
        reconnectTimer = new DispatcherTimer { Interval = delay };
        reconnectTimer.Tick += (_, _) =>
        {
            reconnectTimer?.Stop();
            reconnectTimer = null;
            if (!wantConnected || working) return;
            if (Cisco.State() == VpnState.Connected) { CancelReconnect(); Refresh(); return; }
            ConnectNow(auto: true);
        };
        reconnectTimer.Start();
        Render();
    }

    void ConnectNow(bool auto)
    {
        if (working) return;
        Log.Write(auto ? $"reconnecting (attempt {reconnectAttempts})" : "connect requested by user");
        if (!auto) CancelReconnect();
        var password = Secrets.Get("password");
        if (string.IsNullOrEmpty(password) || string.IsNullOrEmpty(settings.Username)) { EditCredentials(); return; }
        var pin = Secrets.Get("pin");
        var totp = Totp.SecretBytes(Secrets.Get("totp"));
        var (host, group, user) = (settings.Host, settings.Group, settings.Username);
        activity = auto ? "Reconnecting…" : "Connecting…";

        Run(() =>
        {
            if (Cisco.QuitGui()) System.Threading.Thread.Sleep(800);   // let the Cisco window close first
            Cisco.SetDefaultGroup(group);
            var before = Cisco.TunnelAddresses();
            var r = Cisco.Connect(host, group, user, password, pin, totp, () => ui.Invoke(Dialogs.AskCode));
            if (!r.ok) return (false, r.message, r.log, null, null);
            // The new tunnel address, straight from the interfaces; `vpncli stats` only as a fallback.
            var newIp = Cisco.TunnelAddresses().Except(before).FirstOrDefault() ?? Cisco.Info().ip;
            return (true, null, r.log, VpnState.Connected, newIp);
        }, (ok, message) =>
        {
            Log.Write(ok ? "connected" : $"connect failed: {message ?? "cancelled"}");
            if (ok)
            {
                wantConnected = true;
                CancelReconnect();
                Notify(auto ? "VPN reconnected" : "VPN connected", $"{settings.Host} · {ip}");
            }
            else if (!auto || message == null || message.StartsWith("Login rejected"))
            {
                // A manual failure, a cancel or a wrong password: retrying would not help.
                wantConnected = false;
                CancelReconnect();
            }
            else
            {
                ScheduleReconnect();
            }
        });
    }

    /// `seen` is the state the job observed (null = ask Cisco); `newIp` is the tunnel address after a connect.
    void Run(Func<(bool ok, string? message, string log, VpnState? seen, string? newIp)> job, Action<bool, string?>? done = null)
    {
        working = true;
        Render();
        Cisco.CancelStatusCheck();   // do not wait seconds behind a background `vpncli state`/`stats`
        Task.Run(() =>
        {
            var (ok, message, log, seen, newIp) = job();
            var s = seen ?? Cisco.State();
            ui.BeginInvoke(() =>
            {
                working = false;
                state = s;
                if (s == VpnState.Connected)
                {
                    if (newIp != null) { ip = newIp; connectedSince = DateTime.Now; }
                }
                else { ip = null; connectedSince = null; }
                lastTunnels = Cisco.TunnelAddresses();
                done?.Invoke(ok, message);
                Render();
                if (s == VpnState.Connected && ip == null) Refresh(force: true);
                // Auto-reconnect failures stay quiet until it gives up.
                if (!ok && message != null && reconnectTimer == null)
                    Dialogs.Message("VPN connection failed", message, log);
            });
        });
    }

    // --- tray icon: a shield, filled with the state colour, outlined when disconnected ---

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    Icon? currentIcon;

    void SetTrayIcon(Color? fill)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var shield = new GraphicsPath();
            shield.AddLine(16, 2, 28, 6.5f);
            shield.AddBezier(28, 6.5f, 28.5f, 18, 24, 25, 16, 30);
            shield.AddBezier(16, 30, 8, 25, 3.5f, 18, 4, 6.5f);
            shield.CloseFigure();
            if (fill is { } c)
            {
                using var b = new SolidBrush(c);
                g.FillPath(b, shield);
                // padlock
                using var white = new SolidBrush(Color.White);
                using var pen = new Pen(Color.White, 2.4f);
                g.DrawArc(pen, 12, 9, 8, 9, 180, 180);
                g.FillRectangle(white, 10.5f, 14, 11, 9);
            }
            else
            {
                var fg = Theme.TaskbarUsesLight ? Color.FromArgb(0x1B, 0x1B, 0x1B) : Color.White;
                using var pen = new Pen(fg, 2.4f);
                g.DrawPath(pen, shield);
            }
        }
        var handle = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(handle).Clone();
        DestroyIcon(handle);
        tray.Icon = icon;
        currentIcon?.Dispose();
        currentIcon = icon;
    }

    public void Dispose()
    {
        poll.Stop();
        CancelReconnect();
        tray.Visible = false;
        tray.Dispose();
        currentIcon?.Dispose();
    }
}

/// "Launch at startup" through the per-user Run key.
public static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool Enabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("VPNToggle") != null;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("VPNToggle", $"\"{Environment.ProcessPath}\" --startup");
            else key.DeleteValue("VPNToggle", false);
        }
    }
}
