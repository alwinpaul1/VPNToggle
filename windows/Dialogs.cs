using System;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ZXing;
using ZXing.Windows.Compatibility;
using Button = System.Windows.Controls.Button;
using Orientation = System.Windows.Controls.Orientation;
using TextBox = System.Windows.Controls.TextBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using FontFamily = System.Windows.Media.FontFamily;

namespace VPNToggle;

/// Small themed dialogs built in code: credentials, the 2FA code prompt, and one-line messages.
public static class Dialogs
{
    static Window MakeWindow(string title, double width)
    {
        var w = new Window
        {
            Title = title,
            Width = width,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            Topmost = true,
            ShowInTaskbar = true,
        };
        try { w.Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/app.ico")); } catch { }
        w.SourceInitialized += (_, _) => Theme.StyleWindow(w, acrylic: false);
        return w;
    }

    static TextBlock Label(string text, double size = 13, bool secondary = true)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4) };
        if (secondary) t.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondary");
        return t;
    }

    static StackPanel Buttons(Window w, string okText, Action ok)
    {
        var okButton = new Button { Content = okText, Style = (Style)Application.Current.Resources["PrimaryButton"], Width = 110, IsDefault = true, Height = 32 };
        okButton.SetResourceReference(Control.BackgroundProperty, "Accent");
        okButton.Click += (_, _) => ok();
        var cancel = new Button { Content = "Cancel", Style = (Style)Application.Current.Resources["SecondaryButton"], Width = 90, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        cancel.Click += (_, _) => w.DialogResult = false;
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        row.Children.Add(okButton);
        row.Children.Add(cancel);
        return row;
    }

    /// Returns true when saved.
    public static bool EditCredentials(Settings settings)
    {
        var w = MakeWindow("VPN Credentials", 420);
        var host = new TextBox { Text = settings.Host };
        var group = new TextBox { Text = settings.Group };
        var user = new TextBox { Text = settings.Username };
        var pass = new PasswordBox { Password = Secrets.Get("password") ?? "" };
        var pin = new PasswordBox { Password = Secrets.Get("pin") ?? "" };
        var totp = new PasswordBox { Password = Secrets.Get("totp") ?? "" };

        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 20) };
        panel.Children.Add(new TextBlock { Text = "VPN Credentials", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        panel.Children.Add(Label("Secrets are kept in Windows Credential Manager. Add the 2FA secret to have codes generated automatically."));
        void Field(string label, Control box)
        {
            var l = Label(label, 12);
            l.Margin = new Thickness(0, 12, 0, 4);
            panel.Children.Add(l);
            panel.Children.Add(box);
        }
        Field("Server", host);
        Field("Group", group);
        Field("Username", user);
        Field("Password", pass);
        Field("Static PIN (only if your login asks for one)", pin);
        Field("2FA secret (base32, otpauth:// link, or a Google Authenticator export)", totp);

        var qr = new Button { Content = "Read QR image…", Style = (Style)Application.Current.Resources["SecondaryButton"], HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        qr.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif", Title = "Screenshot or photo of the Google Authenticator export QR" };
            if (dlg.ShowDialog(w) != true) return;
            var text = ReadQr(dlg.FileName);
            if (text != null && Totp.SecretBytes(text) != null)
            {
                totp.Password = text;
                Message("2FA secret read", "Click Save to store it, then delete the image.");
            }
            else
            {
                Message("No usable 2FA secret found", "The image needs one readable QR code with the BTU entry. Export only that account.");
            }
        };
        panel.Children.Add(qr);

        var saved = false;
        panel.Children.Add(Buttons(w, "Save", () =>
        {
            if (totp.Password.Trim().Length > 0 && Totp.SecretBytes(totp.Password) == null)
            {
                Message("Invalid 2FA secret", "It must be base32, an otpauth:// link or a Google Authenticator export.");
                return;
            }
            settings.Host = host.Text.Trim();
            settings.Group = group.Text.Trim();
            settings.Username = user.Text.Trim();
            settings.Save();
            Secrets.Set("password", pass.Password);
            Secrets.Set("pin", pin.Password);
            Secrets.Set("totp", totp.Password.Trim());
            saved = true;
            w.DialogResult = true;
        }));
        w.Content = panel;
        w.Loaded += (_, _) => (string.IsNullOrEmpty(pass.Password) ? (Control)pass : user).Focus();
        w.ShowDialog();
        return saved;
    }

    static string? ReadQr(string path)
    {
        try
        {
            using var bmp = (Bitmap)System.Drawing.Image.FromFile(path);
            var reader = new BarcodeReader
            {
                AutoRotate = true,
                Options = { TryHarder = true, PossibleFormats = new[] { BarcodeFormat.QR_CODE } },
            };
            return reader.Decode(bmp)?.Text;
        }
        catch { return null; }
    }

    /// Asks for the current 2FA code; null when cancelled.
    public static string? AskCode()
    {
        var w = MakeWindow("2FA code", 340);
        var box = new TextBox
        {
            FontSize = 24,
            Height = 46,
            TextAlignment = TextAlignment.Center,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            MaxLength = 8,
        };
        string? result = null;
        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 20) };
        panel.Children.Add(new TextBlock { Text = "2FA code", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        panel.Children.Add(Label("Enter the current code from your authenticator app."));
        box.Margin = new Thickness(0, 12, 0, 0);
        panel.Children.Add(box);
        panel.Children.Add(Buttons(w, "Connect", () => { result = box.Text.Trim(); w.DialogResult = true; }));
        w.Content = panel;
        w.Loaded += (_, _) => box.Focus();
        w.ShowDialog();
        return string.IsNullOrEmpty(result) ? null : result;
    }

    /// One line for the user; the full Cisco output only goes to the clipboard on request.
    public static void Message(string title, string message, string? details = null)
    {
        var w = MakeWindow(title, 400);
        var panel = new StackPanel { Margin = new Thickness(24, 20, 24, 20) };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(Label(message, 13));
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        if (!string.IsNullOrEmpty(details))
        {
            var copy = new Button { Content = "Copy details", Style = (Style)Application.Current.Resources["SecondaryButton"], Margin = new Thickness(0, 0, 8, 0) };
            copy.Click += (_, _) => { Clipboard.SetText(details); w.Close(); };
            row.Children.Add(copy);
        }
        var ok = new Button { Content = "OK", Style = (Style)Application.Current.Resources["PrimaryButton"], Width = 90, Height = 32, IsDefault = true, IsCancel = true };
        ok.SetResourceReference(Control.BackgroundProperty, "Accent");
        ok.Click += (_, _) => w.Close();
        row.Children.Add(ok);
        panel.Children.Add(row);
        w.Content = panel;
        w.ShowDialog();
    }
}
