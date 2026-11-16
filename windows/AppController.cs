using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Drawing.Drawing2D;
using System.Net.Http;
using System.Net.NetworkInformation;
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
    readonly DispatcherTimer poll = new() { Interval = StatusPolicy.UnsettledPoll };
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly DispatcherTimer settle = new() { Interval = TimeSpan.FromSeconds(10) };
    readonly Dictionary<Color, (WpfBrush tint, WpfBrush outline)> brushes = new();
    const bool WatchingInterfaces = true;
    bool checking;
    bool recheck;
    string? step;
    string subtitle = "";

    VpnState state = VpnState.Unknown;
    /// The tunnel's address while connected; polling just checks it is still on an interface.
    string? ip;
    DateTime? connectedSince;
    HashSet<string> lastTunnels = new();
    DateTime nextSlowCheck = DateTime.MinValue;
    string? Duration => connectedSince is { } t ? Cisco.FormatDuration((int)(DateTime.Now - t).TotalSeconds) : null;
    bool working;
    string? activity;
    /// True from a successful connect until the user disconnects; a drop in between triggers a reconnect.
    bool wantConnected;
    int reconnectAttempts;
    DispatcherTimer? reconnectTimer;
    static readonly HttpClient Http = CreateHttp();
    readonly string currentVersion = RunningVersion();
    bool checkingForUpdates;

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
        card.NvmPauseStatus = NvmPause.CurrentStatus;
        card.NvmPauseRequested = ChangeNvmPause;
        card.CheckForUpdatesRequested += () => CheckForUpdates(manual: true);
        card.UpdateRequested += InstallUpdate;
        card.UpdateDismissed += DismissUpdate;
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
        settle.Tick += (_, _) => { settle.Stop(); Refresh(force: true); };
        NetworkChange.NetworkAddressChanged += OnAddressChanged;
        tick.Tick += (_, _) => UpdateStatusLine();
        card.IsVisibleChanged += (_, _) =>
        {
            if (card.IsVisible) { UpdateStatusLine(); tick.Start(); }
            else tick.Stop();
        };
        hover.Showing += Render;
        // Cisco drops the tunnel on sleep; check soon after resume so a reconnect starts quickly.
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume)
                ui.BeginInvoke(async () => { await Task.Delay(8000); Refresh(force: true); });
        };

        var firstUpdateCheck = true;
        var updates = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        updates.Tick += (_, _) =>
        {
            updates.Interval = TimeSpan.FromHours(1);
            var due = firstUpdateCheck || UpdatePolicy.ShouldCheck(DateTime.UtcNow, settings.UpdateLastCheck);
            firstUpdateCheck = false;
            if (due) CheckForUpdates(manual: false);
        };
        updates.Start();

        Log.Write($"app started {currentVersion}".TrimEnd());
        Render();
        RenderUpdate();
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

    static HttpClient CreateHttp()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(UpdatePolicy.UserAgent);
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return http;
    }

    static string RunningVersion()
    {
        var v = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
        if (v == null || (v.Major == 0 && v.Minor == 0 && v.Build <= 0)) return "";
        return v.Build > 0 ? $"{v.Major}.{v.Minor}.{v.Build}" : $"{v.Major}.{v.Minor}";
    }

    void RenderUpdate()
    {
        var latest = settings.UpdateLatestTag;
        var shows = latest != null && UpdatePolicy.ShowsBanner(latest, currentVersion, settings.UpdateDismissedTag);
        vm.UpdateDetail = shows && latest != null ? $"Version {UpdatePolicy.DisplayVersion(latest)} · you have {currentVersion}" : "";
        vm.UpdateAvailable = shows;
    }

    UpdatePhase updatePhase = UpdatePhase.Idle;

    void SetUpdatePhase(UpdatePhase phase)
    {
        updatePhase = phase;
        vm.UpdateButton = UpdatePolicy.ButtonTitle(phase);
        vm.UpdateIdle = !UpdatePolicy.Busy(phase);
    }

    void InstallUpdate()
    {
        if (UpdatePolicy.Busy(updatePhase)) return;
        var exe = Environment.ProcessPath;
        if (exe == null) { OpenUpdatePage(); return; }
        SetUpdatePhase(UpdatePolicy.Next(updatePhase, UpdateEvent.Start));
        Log.Write($"update: install requested, running {(currentVersion.Length == 0 ? "unknown" : currentVersion)}");
        Task.Run(() =>
        {
            var refusal = SelfUpdate.Run(exe, currentVersion, UpdatePolicy.Production,
                e => ui.BeginInvoke(() => SetUpdatePhase(UpdatePolicy.Next(updatePhase, e))));
            ui.BeginInvoke(() =>
            {
                if (refusal == null)
                {
                    try
                    {
                        Log.Write("update: installed, restarting");
                        Dispose();
                    }
                    catch { }
                    Environment.Exit(0);
                    return;
                }
                SetUpdatePhase(UpdatePolicy.Next(updatePhase, UpdateEvent.Reset));
                var reason = UpdatePolicy.Message(refusal);
                Log.Write($"update: not installed: {refusal.Kind} {refusal.Detail}".TrimEnd());
                card.HideCard();
                var answer = System.Windows.MessageBox.Show(reason + "\n\nOpen the release page to download it yourself?",
                    "The update was not installed", System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Warning);
                if (answer == System.Windows.MessageBoxResult.Yes) OpenUpdatePage();
            });
        });
    }

    public void AfterUpdate()
    {
        Log.Write($"update: now running {(currentVersion.Length == 0 ? "unknown" : currentVersion)}");
        if (!NvmPause.CopyStale(currentVersion)) return;
        var answer = System.Windows.MessageBox.Show(
            "The Network Visibility pause still runs the previous version of VPNToggle. Refresh it now? Windows will ask for administrator rights once.",
            "VPNToggle was updated", System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question);
        if (answer == System.Windows.MessageBoxResult.Yes) ChangeNvmPause(NvmStatus.Off);
    }

    void OpenUpdatePage()
    {
        card.HideCard();
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(UpdatePolicy.Page(settings.UpdateLatestPage)) { UseShellExecute = true });
        }
        catch (Exception e)
        {
            Log.Write($"could not open the release page: {e.Message}");
        }
    }

    void DismissUpdate()
    {
        settings.UpdateDismissedTag = settings.UpdateLatestTag;
        settings.Save();
        RenderUpdate();
    }

    async void CheckForUpdates(bool manual)
    {
        if (checkingForUpdates) return;
        checkingForUpdates = true;
        ReleaseInfo? release = null;
        var failure = "GitHub's answer could not be read.";
        try
        {
            using var response = await Http.GetAsync(UpdatePolicy.LatestReleaseApi);
            if (response.IsSuccessStatusCode) release = UpdatePolicy.ReleaseFromJson(await response.Content.ReadAsStringAsync());
            else failure = $"GitHub answered with status {(int)response.StatusCode}.";
        }
        catch (Exception e)
        {
            failure = e.Message;
        }
        finally
        {
            checkingForUpdates = false;
        }

        if (release == null)
        {
            Log.Write($"update check failed: {failure}");
            if (manual)
            {
                card.HideCard();
                Dialogs.Message("Could not check for updates", failure);
            }
            return;
        }

        var newer = UpdatePolicy.IsNewer(release.Tag, currentVersion);
        Log.Write($"update check: latest {release.Tag}, running {(currentVersion.Length == 0 ? "unknown" : currentVersion)}");
        settings.UpdateLastCheck = DateTime.UtcNow;
        settings.UpdateLatestTag = release.Tag;
        settings.UpdateLatestPage = release.Page;
        if (manual && newer) settings.UpdateDismissedTag = null;
        try { settings.Save(); }
        catch (Exception e) { Log.Write($"could not save settings: {e.Message}"); }
        RenderUpdate();
        if (!manual) return;
        if (newer)
        {
            if (!card.IsVisible) OpenCard(nearTray: true);
            return;
        }
        card.HideCard();
        Dialogs.Message("You're up to date", currentVersion.Length == 0
            ? $"The latest release is VPNToggle {UpdatePolicy.DisplayVersion(release.Tag)}."
            : $"VPNToggle {currentVersion} is the latest version.");
    }

    void Notify(string title, string body) => tray.ShowBalloonTip(5000, title, body, ToolTipIcon.None);

    // --- state ---

    void OnAddressChanged(object? sender, EventArgs e) => ui.BeginInvoke(() => Refresh());

    /// Cheap check: is the tunnel's address still up? It runs when a network address changes and on a
    /// slow timer. Cisco's slow CLI runs only when the answer is unclear (tunnel gone, addresses changed,
    /// nothing known yet) or at the interval StatusPolicy gives for the current state.
    void Refresh(bool force = false)
    {
        if (working) return;
        var tunnels = Cisco.TunnelAddresses();
        var changed = !tunnels.SetEquals(lastTunnels);
        lastTunnels = tunnels;
        if (ip != null && tunnels.Contains(ip)) { Apply(VpnState.Connected, null); return; }
        if (!StatusPolicy.NeedsCli(force, changed, ip != null, DateTime.Now, nextSlowCheck)) return;
        if (changed && state != VpnState.Unknown) { settle.Stop(); settle.Start(); }
        if (checking) { recheck = true; return; }
        checking = true;
        nextSlowCheck = DateTime.Now + StatusPolicy.CliInterval(state, WatchingInterfaces);
        Task.Run(() =>
        {
            (VpnState state, string? ip, int? seconds)? reading = working ? null : Cisco.Status(early =>
            {
                if (early != VpnState.Connected) return;
                ui.BeginInvoke(() =>
                {
                    if (checking && !working && state != VpnState.Connected) Apply(VpnState.Connected, null);
                });
            });
            ui.BeginInvoke(() =>
            {
                checking = false;
                if (reading is { } r && !working)
                {
                    nextSlowCheck = DateTime.Now + StatusPolicy.CliInterval(r.state, WatchingInterfaces);
                    (string? ip, int? seconds)? learned = r.state == VpnState.Connected ? (r.ip, r.seconds) : null;
                    Apply(r.state, learned);
                }
                if (recheck) { recheck = false; Refresh(force: true); }
            });
        });
    }

    void SchedulePoll()
    {
        var interval = StatusPolicy.PollInterval(StatusPolicy.Settled(state, ip, lastTunnels), WatchingInterfaces);
        if (poll.Interval != interval) poll.Interval = interval;
    }

    (WpfBrush tint, WpfBrush outline) BrushesFor(Color c)
    {
        if (brushes.TryGetValue(c, out var pair)) return pair;
        var tint = new WpfBrush(MediaColor.FromRgb(c.R, c.G, c.B));
        var outline = new WpfBrush(MediaColor.FromArgb(0x8C, c.R, c.G, c.B));
        tint.Freeze();
        outline.Freeze();
        pair = (tint, outline);
        brushes[c] = pair;
        return pair;
    }

    void ChangeNvmPause(NvmStatus current)
    {
        var install = NvmPolicy.Installs(current);
        Task.Run(() =>
        {
            var failure = NvmPause.Change(install);
            var now = NvmPause.CurrentStatus();
            Log.Write($"network visibility pause {(install ? "install" : "uninstall")}: {failure ?? "done"}, now {now}");
            if (failure != null) ui.BeginInvoke(() => Dialogs.Message("Network Visibility pause", failure));
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
        else if (state == VpnState.Busy) { color = Gray; title = "Changing state…"; glyph = "\uE7E8"; }
        else { color = Gray; title = "Not connected"; glyph = "\uE7E8"; }

        var reconnectNote = StatusPolicy.ReconnectNote(reconnectAttempts, ReconnectDelays.Length, settings.AutoReconnect);
        subtitle = working ? step ?? (activity == "Disconnecting…" ? "Closing the tunnel" : $"Signing in to {settings.Host}")
            : connected ? ""
            : dropped ? reconnectNote
            : state == VpnState.Unknown ? "Asking Cisco Secure Client"
            : state == VpnState.Busy ? "Cisco is changing the connection"
            : "Your traffic goes out directly";

        var (tintBrush, outlineBrush) = BrushesFor(color);
        vm.Host = settings.Host;
        vm.Title = title;
        vm.Glyph = glyph;
        vm.Tint = tintBrush;
        vm.Connected = connected;
        vm.Busy = working;
        vm.Ip = ip ?? "—";
        vm.Duration = Duration ?? "—";
        vm.ButtonText = connected ? "Turn the VPN off" : "Turn the VPN on";
        var lit = connected || (dropped && !working);
        var secondary = (Brush)System.Windows.Application.Current.Resources["TextSecondary"];
        var primary = (Brush)System.Windows.Application.Current.Resources["TextPrimary"];
        vm.Lit = lit;
        vm.GlyphBrush = lit ? tintBrush : secondary;
        vm.TitleBrush = lit ? tintBrush : primary;
        vm.OutlineBrush = lit ? outlineBrush : System.Windows.Media.Brushes.Transparent;
        UpdateStatusLine();

        vm.HoverTitle = connected ? "VPN connected" : title;
        vm.HoverDetail = connected ? $"{ip} · for {Duration}"
            : working ? step ?? "Please wait"
            : dropped ? reconnectNote
            : "Click for details";
        SetTrayIcon(working ? Blue : connected ? Green : dropped ? Orange : (Color?)null);
        SchedulePoll();
    }

    void UpdateStatusLine()
    {
        if (state == VpnState.Connected && !working && connectedSince is { } t)
        {
            var d = DateTime.Now - t;
            vm.StatusLine = $"{(int)d.TotalHours:00}:{d.Minutes:00}:{d.Seconds:00}";
        }
        else
        {
            vm.StatusLine = subtitle;
        }
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
        var timer = new DispatcherTimer { Interval = delay };
        reconnectTimer = timer;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Task.Run(() =>
            {
                (VpnState state, string? ip, int? seconds)? reading = working ? null : Cisco.Status();
                ui.BeginInvoke(() =>
                {
                    if (reconnectTimer != timer) return;
                    reconnectTimer = null;
                    if (!wantConnected || working) return;
                    if (reading is { } r && r.state == VpnState.Connected)
                    {
                        CancelReconnect();
                        Apply(VpnState.Connected, (r.ip, r.seconds));
                        return;
                    }
                    ConnectNow(auto: true);
                });
            });
        };
        timer.Start();
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
            var r = Cisco.Connect(host, group, user, password, pin, totp, () => ui.Invoke(Dialogs.AskCode),
                next => ui.BeginInvoke(() =>
                {
                    if (!working || step == next) return;
                    step = next;
                    Render();
                }));
            if (!r.ok) return (false, r.message, r.log, null, null);
            // The new tunnel address, straight from the interfaces; `vpncli stats` only as a fallback.
            var newIp = Cisco.TunnelAddresses().Except(before).FirstOrDefault() ?? Cisco.Status().ip;
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
        step = null;
        Render();
        Cisco.CancelStatusCheck();   // do not wait seconds behind a background `vpncli state`/`stats`
        Task.Run(() =>
        {
            var (ok, message, log, seen, newIp) = job();
            var s = seen ?? Cisco.Status().state;
            ui.BeginInvoke(() =>
            {
                working = false;
                step = null;
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
    (Color? fill, bool light) iconKey;

    void SetTrayIcon(Color? fill)
    {
        var key = (fill, light: fill == null && Theme.TaskbarUsesLight);
        if (currentIcon != null && key.Equals(iconKey)) return;
        iconKey = key;
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
                var fg = key.light ? Color.FromArgb(0x1B, 0x1B, 0x1B) : Color.White;
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
        NetworkChange.NetworkAddressChanged -= OnAddressChanged;
        poll.Stop();
        tick.Stop();
        settle.Stop();
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
