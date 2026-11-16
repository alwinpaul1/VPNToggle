using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;

namespace VPNToggle;

public static class SelfUpdate
{
    static HttpClient CreateClient()
    {
        var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(UpdatePolicy.UserAgent);
        return http;
    }

    static UpdateRefusal? Download(HttpClient http, string address, string target, UpdateSource source, long limit, bool followRedirects)
    {
        try
        {
            var url = address;
            for (var hop = 0; hop < 6; hop++)
            {
                using var cancel = new CancellationTokenSource(TimeSpan.FromMinutes(10));
                using var response = http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel.Token).GetAwaiter().GetResult();
                var code = (int)response.StatusCode;
                if (code >= 300 && code < 400)
                {
                    var location = response.Headers.Location;
                    if (!followRedirects || location == null) return new UpdateRefusal(UpdateRefusalKind.UrlNotAllowed);
                    var next = (location.IsAbsoluteUri ? location : new Uri(new Uri(url), location)).AbsoluteUri;
                    if (!UpdatePolicy.RedirectAllowed(next, source)) return new UpdateRefusal(UpdateRefusalKind.UrlNotAllowed);
                    url = next;
                    continue;
                }
                if (response.StatusCode != HttpStatusCode.OK)
                    return new UpdateRefusal(UpdateRefusalKind.DownloadFailed, $"The server answered with status {code}.");
                if (response.Content.Headers.ContentLength is { } length && length > limit)
                    return new UpdateRefusal(UpdateRefusalKind.TooLarge);
                using var input = response.Content.ReadAsStreamAsync(cancel.Token).GetAwaiter().GetResult();
                using var output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None);
                var buffer = new byte[1 << 16];
                long total = 0;
                while (true)
                {
                    var n = input.ReadAsync(buffer, 0, buffer.Length, cancel.Token).GetAwaiter().GetResult();
                    if (n <= 0) break;
                    total += n;
                    if (total > limit) return new UpdateRefusal(UpdateRefusalKind.TooLarge);
                    output.Write(buffer, 0, n);
                }
                return null;
            }
            return new UpdateRefusal(UpdateRefusalKind.DownloadFailed, "Too many redirects.");
        }
        catch (UnauthorizedAccessException) { return new UpdateRefusal(UpdateRefusalKind.NotWritable); }
        catch (Exception e) { return new UpdateRefusal(UpdateRefusalKind.DownloadFailed, e.Message); }
    }

    static string? Sha256Hex(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        }
        catch { return null; }
    }

    static bool LooksLikeProgram(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            return stream.ReadByte() == 'M' && stream.ReadByte() == 'Z';
        }
        catch { return false; }
    }

    static string? FileVersion(string path)
    {
        try { return FileVersionInfo.GetVersionInfo(path).FileVersion; }
        catch { return null; }
    }

    static void Remove(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    static Process? StartWaiter(string exe)
    {
        try
        {
            var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            var command = "Wait-Process -Id $env:VPNTOGGLE_WAIT_FOR -ErrorAction SilentlyContinue; " +
                "Start-Process -FilePath $env:VPNTOGGLE_START -ArgumentList $env:VPNTOGGLE_START_FLAG";
            var psi = new ProcessStartInfo(shell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + command + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.Environment["VPNTOGGLE_WAIT_FOR"] = Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture);
            psi.Environment["VPNTOGGLE_START"] = exe;
            psi.Environment["VPNTOGGLE_START_FLAG"] = UpdatePolicy.UpdatedFlag;
            psi.Environment.Remove(UpdatePolicy.TestApiVariable);
            return Process.Start(psi);
        }
        catch (Exception e)
        {
            Log.Write($"update: could not prepare the restart: {e.Message}");
            return null;
        }
    }

    static void Stop(Process? waiter)
    {
        try { if (waiter != null && !waiter.HasExited) waiter.Kill(); } catch { }
    }

    public static UpdateRefusal? Run(string exe, string currentVersion, UpdateSource source, Action<UpdateEvent>? progress = null)
    {
        try { return RunSteps(exe, currentVersion, source, progress); }
        catch (Exception e) { return new UpdateRefusal(UpdateRefusalKind.SwapFailed, e.Message); }
    }

    static UpdateRefusal? RunSteps(string exe, string currentVersion, UpdateSource source, Action<UpdateEvent>? progress)
    {
        var folder = Path.GetDirectoryName(exe);
        if (folder == null) return new UpdateRefusal(UpdateRefusalKind.NotWritable);
        var fresh = UpdatePolicy.NewPath(exe);
        var json = Path.Combine(Path.GetTempPath(), $"vpntoggle-release-{Guid.NewGuid():N}.json");
        using var http = CreateClient();
        try
        {
            try { using (File.Create(fresh)) { } }
            catch { return new UpdateRefusal(UpdateRefusalKind.NotWritable); }

            var listing = Download(http, source.Api, json, source, 4 << 20, followRedirects: false);
            if (listing != null)
                return listing.Kind == UpdateRefusalKind.DownloadFailed ? new UpdateRefusal(UpdateRefusalKind.NoRelease, listing.Detail) : listing;
            var (plan, refusal) = UpdatePolicy.Plan(File.ReadAllText(json), currentVersion, UpdatePolicy.WindowsAsset, source);
            if (plan == null) return refusal ?? new UpdateRefusal(UpdateRefusalKind.NoRelease);
            progress?.Invoke(UpdateEvent.Planned);

            var failed = Download(http, plan.Url, fresh, source, plan.Size, followRedirects: true);
            if (failed != null) return failed;
            var actual = Sha256Hex(fresh);
            if (actual == null || !UpdatePolicy.DigestMatches(plan.Sha256, actual)) return new UpdateRefusal(UpdateRefusalKind.DigestMismatch);
            progress?.Invoke(UpdateEvent.Downloaded);

            var content = UpdatePolicy.ContentRefusal(LooksLikeProgram(fresh), FileVersion(fresh), currentVersion, plan.Tag);
            if (content != null) return content;
            progress?.Invoke(UpdateEvent.Verified);

            var old = UpdatePolicy.OldPath(exe);
            var waiter = StartWaiter(exe);
            if (waiter == null) return new UpdateRefusal(UpdateRefusalKind.SwapFailed, "The restart could not be prepared.");
            try
            {
                Remove(old);
                File.Move(exe, old);
            }
            catch (Exception e)
            {
                Stop(waiter);
                return new UpdateRefusal(UpdateRefusalKind.SwapFailed, e.Message);
            }
            try { File.Move(fresh, exe); }
            catch (Exception e)
            {
                try { File.Move(old, exe); } catch { }
                Stop(waiter);
                return new UpdateRefusal(UpdateRefusalKind.SwapFailed, e.Message);
            }
            return null;
        }
        finally
        {
            Remove(json);
            Remove(fresh);
        }
    }

    public static void CleanUp()
    {
        var exe = Environment.ProcessPath;
        if (exe == null) return;
        var old = UpdatePolicy.OldPath(exe);
        var fresh = UpdatePolicy.NewPath(exe);
        new Thread(() =>
        {
            for (var attempt = 0; attempt < 40 && (File.Exists(old) || File.Exists(fresh)); attempt++)
            {
                Remove(old);
                Remove(fresh);
                Thread.Sleep(500);
            }
        }) { IsBackground = true }.Start();
    }

    public static int? RunNoticeTestMode(string[] args)
    {
        if (Array.IndexOf(args, UpdatePolicy.NoticeTestFlag) < 0) return null;
        var json = Path.Combine(Path.GetTempPath(), $"vpntoggle-release-{Guid.NewGuid():N}.json");
        try
        {
            var exe = Environment.ProcessPath;
            if (exe == null) return 4;
            var source = UpdatePolicy.Source(Environment.GetEnvironmentVariable(UpdatePolicy.TestApiVariable));
            using var http = CreateClient();
            var failed = Download(http, source.Api, json, source, 4 << 20, followRedirects: false);
            var release = failed == null ? UpdatePolicy.ReleaseFromJson(File.ReadAllText(json)) : null;
            if (release == null)
            {
                Log.Write("update notice test: no release");
                return 3;
            }
            var manual = Array.IndexOf(args, "--manual") >= 0;
            var notify = UpdateNotice.Note(Settings.Load(), release.Tag, FileVersion(exe) ?? "", manual);
            Log.Write(notify ? "update notice test: notice" : "update notice test: no notice");
            return 0;
        }
        catch (Exception e)
        {
            try { Log.Write($"update notice test: failed: {e}"); } catch { }
            return 6;
        }
        finally
        {
            Remove(json);
        }
    }

    public static int? RunTestMode(string[] args)
    {
        if (Array.IndexOf(args, UpdatePolicy.TestFlag) < 0) return null;
        try
        {
            var exe = Environment.ProcessPath;
            if (exe == null) return 4;
            var source = UpdatePolicy.Source(Environment.GetEnvironmentVariable(UpdatePolicy.TestApiVariable));
            var version = FileVersion(exe) ?? "";
            var refusal = Run(exe, version, source);
            if (refusal != null)
            {
                Log.Write($"update test: not installed: {refusal.Kind} {refusal.Detail}".TrimEnd());
                return 3;
            }
            Log.Write("update test: installed, restarting");
            return 0;
        }
        catch (Exception e)
        {
            try { Log.Write($"update test: failed: {e}"); } catch { }
            return 6;
        }
    }
}
