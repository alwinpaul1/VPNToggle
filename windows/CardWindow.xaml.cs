using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace VPNToggle;

/// What the card shows; AppController owns the logic and updates this.
public sealed class CardViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    string host = "";
    public string Host { get => host; set => Set(ref host, value); }

    string title = "Checking…";
    public string Title { get => title; set => Set(ref title, value); }

    string glyph = "";
    public string Glyph { get => glyph; set => Set(ref glyph, value); }

    Brush tint = Brushes.Gray;
    public Brush Tint { get => tint; set => Set(ref tint, value); }

    bool connected;
    public bool Connected { get => connected; set { Set(ref connected, value); OnPropertyChanged(nameof(Glow)); } }

    bool busy;
    public bool Busy { get => busy; set { Set(ref busy, value); OnPropertyChanged(nameof(NotBusy)); } }
    public bool NotBusy => !busy;
    public bool Glow => connected && !busy;

    string? ip;
    public string? Ip { get => ip; set => Set(ref ip, value); }

    string? duration;
    public string? Duration { get => duration; set => Set(ref duration, value); }

    string twoFactor = "";
    public string TwoFactor { get => twoFactor; set => Set(ref twoFactor, value); }

    bool autoReconnect = true;
    public bool AutoReconnect
    {
        get => autoReconnect;
        set { if (autoReconnect == value) return; Set(ref autoReconnect, value); AutoReconnectChanged?.Invoke(value); }
    }
    public void SetAutoReconnectSilently(bool v) => Set(ref autoReconnect, v, nameof(AutoReconnect));
    public event Action<bool>? AutoReconnectChanged;

    string buttonText = "Connect";
    public string ButtonText { get => buttonText; set => Set(ref buttonText, value); }

    Brush buttonBrush = Brushes.SteelBlue;
    public Brush ButtonBrush { get => buttonBrush; set => Set(ref buttonBrush, value); }

    void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public partial class CardWindow : Window
{
    public event Action? ToggleRequested;
    public event Action? CredentialsRequested;
    public event Action? QuitRequested;
    public Func<bool> LaunchAtLogin = () => false;
    public Action<bool> SetLaunchAtLogin = _ => { };
    public Func<string?> CurrentIp = () => null;
    public DateTime HiddenAt { get; private set; }

    public CardWindow(CardViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
        SourceInitialized += (_, _) => Theme.StyleWindow(this, acrylic: true);
        Theme.Changed += () => { if (IsLoaded) Theme.StyleWindow(this, acrylic: true); };
        Deactivated += (_, _) => HideCard();
    }

    void Toggle_Click(object sender, RoutedEventArgs e) => ToggleRequested?.Invoke();

    void More_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = MoreButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        MenuItem Item(string header, Action action, bool? check = null)
        {
            var i = new MenuItem { Header = header };
            if (check.HasValue) { i.IsCheckable = true; i.IsChecked = check.Value; }
            i.Click += (_, _) => action();
            menu.Items.Add(i);
            return i;
        }
        Item("Credentials…", () => { HideCard(); CredentialsRequested?.Invoke(); });
        Item("Launch at startup", () => SetLaunchAtLogin(!LaunchAtLogin()), LaunchAtLogin());
        if (CurrentIp() is { } ip) Item("Copy IP address", () => Clipboard.SetText(ip));
        Item("Show log", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Log.FilePath) { UseShellExecute = true }));
        menu.Items.Add(new Separator());
        Item("Quit VPNToggle", () => QuitRequested?.Invoke());
        menu.IsOpen = true;
    }

    /// Opens just above the system tray (or below it when the taskbar is at the top).
    public void ShowNearTray()
    {
        Opacity = 0;
        Show();
        UpdateLayout();
        var wa = SystemParameters.WorkArea;
        var screen = new Rect(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight);
        Left = wa.Right - ActualWidth - 12;
        var taskbarOnTop = wa.Top > screen.Top;
        Top = taskbarOnTop ? wa.Top + 12 : wa.Bottom - ActualHeight - 12;
        if (wa.Left > screen.Left) Left = wa.Left + 12; // taskbar on the left

        Activate();
        var slide = new DoubleAnimation(taskbarOnTop ? -12 : 12, 0, TimeSpan.FromMilliseconds(220))
        { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        Slide.BeginAnimation(TranslateTransform.YProperty, slide);
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)));
    }

    public void HideCard()
    {
        if (!IsVisible) return;
        HiddenAt = DateTime.Now;
        Hide();
    }
}
