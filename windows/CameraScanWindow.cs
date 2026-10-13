using System;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using ZXing;
using WinCapture = global::Windows.Media.Capture;
using WinFrames = global::Windows.Media.Capture.Frames;
using WinImaging = global::Windows.Graphics.Imaging;

namespace VPNToggle;

/// Live camera QR scanner: hold the Google Authenticator export QR up to the webcam. It stops at the
/// first QR code that holds a usable 2FA secret and ignores any other.
public sealed class CameraScanWindow : Window
{
    WinCapture.MediaCapture? capture;
    WinFrames.MediaFrameReader? reader;
    readonly System.Windows.Controls.Image preview = new() { Stretch = Stretch.UniformToFill };
    readonly TextBlock hint = new()
    {
        Text = "Hold the Google Authenticator export QR code up to the camera",
        FontSize = 13,
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
    };
    readonly BarcodeReaderGeneric decoder = new()
    {
        AutoRotate = false,
        Options = { TryHarder = true, PossibleFormats = new[] { BarcodeFormat.QR_CODE } },
    };
    WriteableBitmap? bitmap;
    volatile bool busy;
    DateTime lastScan;

    public string? Result { get; private set; }

    public CameraScanWindow()
    {
        Title = "Scan QR code";
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        SourceInitialized += (_, _) => Theme.StyleWindow(this, acrylic: false);

        // Mirrored preview (like a selfie view) with a viewfinder square on top.
        preview.RenderTransformOrigin = new Point(0.5, 0.5);
        preview.RenderTransform = new ScaleTransform(-1, 1);
        var finder = new Rectangle
        {
            Width = 240, Height = 240, RadiusX = 22, RadiusY = 22,
            Stroke = Brushes.White, StrokeThickness = 3, Opacity = 0.9,
        };
        var video = new Grid { Height = 400, Background = Brushes.Black, ClipToBounds = true };
        video.Children.Add(preview);
        video.Children.Add(finder);

        var cancel = new Button
        {
            Content = "Cancel",
            Style = (Style)Application.Current.Resources["SecondaryButton"],
            Width = 100,
            IsCancel = true,
            Margin = new Thickness(0, 12, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var bottom = new StackPanel { Margin = new Thickness(20, 14, 20, 18) };
        bottom.Children.Add(hint);
        bottom.Children.Add(cancel);

        var root = new StackPanel();
        root.Children.Add(video);
        root.Children.Add(bottom);
        Content = root;

        Loaded += async (_, _) => await StartAsync();
        Closed += async (_, _) => await StopAsync();
    }

    async Task StartAsync()
    {
        try
        {
            var groups = await WinFrames.MediaFrameSourceGroup.FindAllAsync();
            var group = groups.FirstOrDefault(g => g.SourceInfos.Any(i => i.SourceKind == WinFrames.MediaFrameSourceKind.Color));
            if (group == null) { hint.Text = "No camera found. Use Read QR image… with a screenshot instead."; return; }

            capture = new WinCapture.MediaCapture();
            await capture.InitializeAsync(new WinCapture.MediaCaptureInitializationSettings
            {
                SourceGroup = group,
                SharingMode = WinCapture.MediaCaptureSharingMode.SharedReadOnly,
                StreamingCaptureMode = WinCapture.StreamingCaptureMode.Video,
                MemoryPreference = WinCapture.MediaCaptureMemoryPreference.Cpu,
            });
            var source = capture.FrameSources.Values.First(s => s.Info.SourceKind == WinFrames.MediaFrameSourceKind.Color);
            reader = await capture.CreateFrameReaderAsync(source, global::Windows.Media.MediaProperties.MediaEncodingSubtypes.Bgra8);
            reader.FrameArrived += OnFrame;
            await reader.StartAsync();
        }
        catch (UnauthorizedAccessException)
        {
            hint.Text = "Camera access is off. Turn on Settings → Privacy & security → Camera → \"Let desktop apps access your camera\".";
        }
        catch (Exception ex)
        {
            hint.Text = "Could not start the camera: " + ex.Message;
        }
    }

    void OnFrame(WinFrames.MediaFrameReader r, WinFrames.MediaFrameArrivedEventArgs e)
    {
        if (busy || Result != null) return;
        busy = true;
        try
        {
            using var frame = r.TryAcquireLatestFrame();
            var source = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (source == null) return;
            using var bgra = source.BitmapPixelFormat == WinImaging.BitmapPixelFormat.Bgra8
                ? WinImaging.SoftwareBitmap.Copy(source)
                : WinImaging.SoftwareBitmap.Convert(source, WinImaging.BitmapPixelFormat.Bgra8, WinImaging.BitmapAlphaMode.Premultiplied);
            int w = bgra.PixelWidth, h = bgra.PixelHeight;
            var pixels = new byte[w * h * 4];
            bgra.CopyToBuffer(pixels.AsBuffer());

            Dispatcher.Invoke(() =>
            {
                if (bitmap == null || bitmap.PixelWidth != w || bitmap.PixelHeight != h)
                {
                    bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
                    preview.Source = bitmap;
                }
                bitmap.WritePixels(new Int32Rect(0, 0, w, h), pixels, w * 4, 0);
            });

            // About eight looks a second is plenty and keeps the CPU quiet.
            if ((DateTime.Now - lastScan).TotalMilliseconds < 120) return;
            lastScan = DateTime.Now;
            var text = decoder.Decode(new RGBLuminanceSource(pixels, w, h, RGBLuminanceSource.BitmapFormat.BGRA32))?.Text;
            if (text == null) return;
            if (Totp.SecretBytes(text) != null)
            {
                Result = text;
                Dispatcher.BeginInvoke(() => DialogResult = true);
            }
            else
            {
                Dispatcher.BeginInvoke(() => hint.Text = "That QR code holds no usable 2FA secret. Show the export QR for the BTU account.");
            }
        }
        catch { }
        finally { busy = false; }
    }

    async Task StopAsync()
    {
        try
        {
            if (reader != null)
            {
                reader.FrameArrived -= OnFrame;
                await reader.StopAsync();
                reader.Dispose();
            }
            capture?.Dispose();
        }
        catch { }
    }
}
