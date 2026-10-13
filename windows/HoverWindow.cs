using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Shell;
using System.Windows.Threading;

namespace VPNToggle;

/// The hover peek above the tray icon: a coloured dot, the state and one line of detail.
/// Replaces the plain tray tooltip, like the Mac app's hover card.
public sealed class HoverWindow : Window
{
    readonly DispatcherTimer watch = new() { Interval = TimeSpan.FromMilliseconds(120) };
    System.Drawing.Point anchor;
    DateTime lastMove;

    public HoverWindow(CardViewModel vm)
    {
        DataContext = vm;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        Focusable = false;
        SizeToContent = SizeToContent.WidthAndHeight;
        Background = Brushes.Transparent;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0, GlassFrameThickness = new Thickness(-1), ResizeBorderThickness = new Thickness(0),
            UseAeroCaptionButtons = false,
        });
        SourceInitialized += (_, _) => Theme.StyleWindow(this, acrylic: true);

        var dot = new Ellipse { Width = 9, Height = 9, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
        dot.SetBinding(Shape.FillProperty, new Binding(nameof(CardViewModel.Tint)));
        var title = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold };
        title.SetBinding(TextBlock.TextProperty, new Binding(nameof(CardViewModel.HoverTitle)));
        var detail = new TextBlock { FontSize = 11 };
        detail.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        detail.SetBinding(TextBlock.TextProperty, new Binding(nameof(CardViewModel.HoverDetail)));
        var text = new StackPanel();
        text.Children.Add(title);
        text.Children.Add(detail);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(14, 10, 16, 10) };
        row.Children.Add(dot);
        row.Children.Add(text);
        Content = row;

        // The tray reports moves over the icon but never a "leave"; hide once the pointer has moved off.
        watch.Tick += (_, _) =>
        {
            var p = System.Windows.Forms.Cursor.Position;
            if ((DateTime.Now - lastMove).TotalMilliseconds > 250 &&
                (Math.Abs(p.X - anchor.X) > 14 || Math.Abs(p.Y - anchor.Y) > 14))
                HidePeek();
        };
    }

    /// Called on every tray mouse-move; shows the peek after a short rest.
    public void PointerOverIcon(Func<bool> blocked)
    {
        anchor = System.Windows.Forms.Cursor.Position;
        lastMove = DateTime.Now;
        if (IsVisible || blocked()) return;
        var at = anchor;
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            var p = System.Windows.Forms.Cursor.Position;
            if (Math.Abs(p.X - at.X) > 14 || Math.Abs(p.Y - at.Y) > 14 || blocked()) return;
            ShowAt(at);
        };
        t.Start();
    }

    void ShowAt(System.Drawing.Point pixel)
    {
        Opacity = 0;
        Show();
        UpdateLayout();
        var place = TrayPlacement.Near(this, pixel, ActualWidth, ActualHeight, gap: 10);
        Left = place.X;
        Top = place.Y;
        Opacity = 1;
        watch.Start();
    }

    public void HidePeek()
    {
        watch.Stop();
        if (IsVisible) Hide();
    }
}

/// Places a window just above (or below) the tray, centred on the icon the pointer is over.
public static class TrayPlacement
{
    public static Point Near(Window w, System.Drawing.Point pixel, double width, double height, double gap)
    {
        var src = PresentationSource.FromVisual(w);
        var toDip = src?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var at = toDip.Transform(new Point(pixel.X, pixel.Y));
        var wa = SystemParameters.WorkArea;
        var x = Math.Min(Math.Max(at.X - width / 2, wa.Left + 8), wa.Right - width - 8);
        var taskbarOnTop = wa.Top > 0;
        var y = taskbarOnTop ? wa.Top + gap : wa.Bottom - height - gap;
        if (wa.Left > 0) x = wa.Left + gap;                 // taskbar on the left
        else if (wa.Right < SystemParameters.PrimaryScreenWidth) x = wa.Right - width - gap; // on the right
        return new Point(x, y);
    }
}
