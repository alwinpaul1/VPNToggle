using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;

public sealed record ReleaseInfo(string Tag, string Page);

public sealed record ReleaseAsset(string Name, string Url, string? Digest, long Size);

public sealed record UpdateSource(string Api, string DownloadPrefix, string[] RedirectHosts, string Scheme);

public sealed record UpdatePlan(string Tag, string Url, string Sha256, long Size);

public enum UpdateRefusalKind
{
    NoRelease, NotNewer, NoAsset, UrlNotAllowed, MissingDigest, TooLarge, DownloadFailed,
    DigestMismatch, WrongApp, NotWritable, SwapFailed,
}

public sealed record UpdateRefusal(UpdateRefusalKind Kind, string Detail = "");

public enum UpdatePhase { Idle, Checking, Downloading, Verifying, Installing, Relaunching, Failed }

public enum UpdateEvent { Start, Planned, Downloaded, Verified, Installed, Refused, Reset }

public static class UpdatePolicy
{
    public const string LatestReleaseApi = "https://api.github.com/repos/alwinpaul1/VPNToggle/releases/latest";
    public const string ReleasesPage = "https://github.com/alwinpaul1/VPNToggle/releases/latest";
    public const string TrustedPagePrefix = "https://github.com/alwinpaul1/VPNToggle/releases/";
    public const string UserAgent = "VPNToggle";
    public static readonly TimeSpan CheckInterval = TimeSpan.FromDays(1);

    public static int[]? Segments(string? version)
    {
        if (version == null) return null;
        var text = version.Trim();
        if (text.StartsWith("v", StringComparison.OrdinalIgnoreCase)) text = text.Substring(1);
        var parts = text.Split('.');
        var numbers = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            var part = parts[i];
            if (part.Length == 0 || part.Length > 9 || !part.All(c => c >= '0' && c <= '9')) return null;
            numbers[i] = int.Parse(part, NumberStyles.None, CultureInfo.InvariantCulture);
        }
        return numbers;
    }

    public static bool IsNewer(string? latest, string? current)
    {
        var a = Segments(latest);
        var b = Segments(current);
        if (a == null || b == null) return false;
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    public static bool SameVersion(string? a, string? b)
    {
        if (Segments(a) == null || Segments(b) == null) return false;
        return !IsNewer(a, b) && !IsNewer(b, a);
    }

    public static string DisplayVersion(string tag)
    {
        var numbers = Segments(tag);
        return numbers == null ? tag : string.Join(".", numbers.Select(n => n.ToString(CultureInfo.InvariantCulture)));
    }

    public static bool ShouldCheck(DateTime now, DateTime? lastCheck, TimeSpan? interval = null)
    {
        if (lastCheck == null) return true;
        var elapsed = now - lastCheck.Value;
        return elapsed >= (interval ?? CheckInterval) || elapsed < TimeSpan.Zero;
    }

    public static bool ShowsBanner(string? latest, string? current, string? dismissed)
    {
        if (latest == null || !IsNewer(latest, current)) return false;
        return dismissed == null || !SameVersion(dismissed, latest);
    }

    public static string Page(string? candidate)
    {
        if (candidate == null || !candidate.StartsWith(TrustedPagePrefix, StringComparison.Ordinal) || candidate.Any(char.IsWhiteSpace))
            return ReleasesPage;
        return candidate;
    }

    public static ReleaseInfo? ReleaseFromJson(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("tag_name", out var tagElement) || tagElement.ValueKind != JsonValueKind.String) return null;
            var tag = tagElement.GetString();
            if (tag == null || Segments(tag) == null) return null;
            if (root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) return null;
            if (root.TryGetProperty("prerelease", out var prerelease) && prerelease.ValueKind == JsonValueKind.True) return null;
            var page = root.TryGetProperty("html_url", out var pageElement) && pageElement.ValueKind == JsonValueKind.String
                ? pageElement.GetString()
                : null;
            return new ReleaseInfo(tag, Page(page));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public const string WindowsAsset = "VPNToggle.exe";
    public const long MaxAssetBytes = 300L * 1024 * 1024;
    public const string TestApiVariable = "VPNTOGGLE_UPDATE_TEST_API";
    public const string TestFlag = "--self-update-test";
    public const string UpdatedFlag = "--updated";

    public static readonly UpdateSource Production = new(
        LatestReleaseApi,
        "https://github.com/alwinpaul1/VPNToggle/releases/download/",
        new[] { "objects.githubusercontent.com", "release-assets.githubusercontent.com" },
        "https");

    public static UpdateSource Source(string? testApi)
    {
        if (testApi == null || !Uri.TryCreate(testApi, UriKind.Absolute, out var uri)) return Production;
        if (uri.Scheme != "http" || uri.UserInfo.Length != 0 || uri.IsDefaultPort) return Production;
        if (uri.Host != "127.0.0.1" && uri.Host != "localhost") return Production;
        if (!testApi.StartsWith($"http://{uri.Host}:{uri.Port}/", StringComparison.Ordinal)) return Production;
        return new UpdateSource(testApi, $"http://{uri.Host}:{uri.Port}/", Array.Empty<string>(), "http");
    }

    public static Uri? CleanUrl(string? text, string scheme)
    {
        if (string.IsNullOrEmpty(text) || text.Any(c => char.IsWhiteSpace(c) || c == '\\' || c == '@')) return null;
        if (!text.StartsWith(scheme + "://", StringComparison.Ordinal)) return null;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme != scheme || uri.UserInfo.Length != 0 || uri.Host.Length == 0) return null;
        var rest = text.Substring(scheme.Length + 3);
        var slash = rest.IndexOf('/');
        var path = (slash < 0 ? "" : rest.Substring(slash)).Split('?')[0].ToLowerInvariant();
        if (path.Contains("..") || path.Contains("%2e") || path.Contains("%2f") || path.Contains("%5c")) return null;
        return uri;
    }

    public static bool DownloadAllowed(string? url, UpdateSource? source = null)
    {
        source ??= Production;
        if (url == null || CleanUrl(url, source.Scheme) == null) return false;
        return url.StartsWith(source.DownloadPrefix, StringComparison.Ordinal) && url.Length > source.DownloadPrefix.Length;
    }

    public static bool RedirectAllowed(string? url, UpdateSource? source = null)
    {
        source ??= Production;
        if (DownloadAllowed(url, source)) return true;
        var uri = CleanUrl(url, source.Scheme);
        return uri != null && source.RedirectHosts.Contains(uri.Host.ToLowerInvariant());
    }

    public static string? Sha256FromDigest(string? digest)
    {
        if (digest == null || !digest.StartsWith("sha256:", StringComparison.Ordinal)) return null;
        var hex = digest.Substring("sha256:".Length);
        if (hex.Length != 64 || !hex.All(Uri.IsHexDigit)) return null;
        return hex.ToLowerInvariant();
    }

    public static bool DigestMatches(string expected, string actualHex) =>
        expected.Length == 64 && string.Equals(expected, actualHex, StringComparison.OrdinalIgnoreCase);

    public static List<ReleaseAsset> Assets(string json)
    {
        var list = new List<ReleaseAsset>();
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return list;
            if (!root.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return list;
            foreach (var item in assets.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                if (!item.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String) continue;
                if (!item.TryGetProperty("browser_download_url", out var url) || url.ValueKind != JsonValueKind.String) continue;
                var digest = item.TryGetProperty("digest", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() : null;
                var size = item.TryGetProperty("size", out var z) && z.ValueKind == JsonValueKind.Number && z.TryGetInt64(out var bytes) ? bytes : 0;
                list.Add(new ReleaseAsset(name.GetString()!, url.GetString()!, digest, size));
            }
        }
        catch (JsonException)
        {
            list.Clear();
        }
        return list;
    }

    public static (UpdatePlan? plan, UpdateRefusal? refusal) Plan(string json, string? current, string assetName, UpdateSource? source = null)
    {
        source ??= Production;
        var release = ReleaseFromJson(json);
        if (release == null) return (null, new UpdateRefusal(UpdateRefusalKind.NoRelease, "GitHub's answer could not be read."));
        if (!IsNewer(release.Tag, current)) return (null, new UpdateRefusal(UpdateRefusalKind.NotNewer));
        var matches = Assets(json).Where(a => a.Name == assetName).ToList();
        if (matches.Count != 1) return (null, new UpdateRefusal(UpdateRefusalKind.NoAsset));
        var asset = matches[0];
        if (!DownloadAllowed(asset.Url, source)) return (null, new UpdateRefusal(UpdateRefusalKind.UrlNotAllowed));
        var hash = Sha256FromDigest(asset.Digest);
        if (hash == null) return (null, new UpdateRefusal(UpdateRefusalKind.MissingDigest));
        if (asset.Size <= 0 || asset.Size > MaxAssetBytes) return (null, new UpdateRefusal(UpdateRefusalKind.TooLarge));
        return (new UpdatePlan(release.Tag, asset.Url, hash, asset.Size), null);
    }

    public static UpdateRefusal? ContentRefusal(bool looksLikeProgram, string? fileVersion, string? current, string tag)
    {
        if (!looksLikeProgram || !IsNewer(fileVersion, current) || !SameVersion(fileVersion, tag))
            return new UpdateRefusal(UpdateRefusalKind.WrongApp);
        return null;
    }

    public static bool Busy(UpdatePhase phase) => phase != UpdatePhase.Idle && phase != UpdatePhase.Failed;

    public static UpdatePhase Next(UpdatePhase phase, UpdateEvent e)
    {
        if (e == UpdateEvent.Reset) return UpdatePhase.Idle;
        if (phase == UpdatePhase.Relaunching) return UpdatePhase.Relaunching;
        if (e == UpdateEvent.Refused) return Busy(phase) ? UpdatePhase.Failed : phase;
        return (phase, e) switch
        {
            (UpdatePhase.Idle, UpdateEvent.Start) => UpdatePhase.Checking,
            (UpdatePhase.Failed, UpdateEvent.Start) => UpdatePhase.Checking,
            (UpdatePhase.Checking, UpdateEvent.Planned) => UpdatePhase.Downloading,
            (UpdatePhase.Downloading, UpdateEvent.Downloaded) => UpdatePhase.Verifying,
            (UpdatePhase.Verifying, UpdateEvent.Verified) => UpdatePhase.Installing,
            (UpdatePhase.Installing, UpdateEvent.Installed) => UpdatePhase.Relaunching,
            _ => phase,
        };
    }

    public static string ButtonTitle(UpdatePhase phase) => phase switch
    {
        UpdatePhase.Checking or UpdatePhase.Downloading => "Downloading…",
        UpdatePhase.Verifying or UpdatePhase.Installing => "Installing…",
        UpdatePhase.Relaunching => "Restarting…",
        _ => "Install update",
    };

    public static string Message(UpdateRefusal refusal) => refusal.Kind switch
    {
        UpdateRefusalKind.NoRelease => $"Could not read the latest release. {refusal.Detail}".TrimEnd(),
        UpdateRefusalKind.NotNewer => "This is already the latest version.",
        UpdateRefusalKind.NoAsset => "The latest release has no download for this computer.",
        UpdateRefusalKind.UrlNotAllowed => "The download link does not point to VPNToggle's releases on GitHub, so it was not used.",
        UpdateRefusalKind.MissingDigest => "The release lists no checksum for the download, so it was not used.",
        UpdateRefusalKind.TooLarge => "The download has an unexpected size, so it was not used.",
        UpdateRefusalKind.DownloadFailed => $"The download did not finish. {refusal.Detail}".TrimEnd(),
        UpdateRefusalKind.DigestMismatch => "The downloaded file does not match the checksum of the release. It was deleted.",
        UpdateRefusalKind.WrongApp => "The download is not a newer VPNToggle.",
        UpdateRefusalKind.NotWritable => "VPNToggle cannot write to the folder it is installed in.",
        _ => $"The new version could not be put in place. {refusal.Detail}".TrimEnd(),
    };

    public static string OldPath(string exe) => exe + ".old";

    public static string NewPath(string exe) => exe + ".new";

    public static bool CopyStale(string? copyVersion, string? runningVersion) =>
        Segments(copyVersion) != null && Segments(runningVersion) != null && !SameVersion(copyVersion, runningVersion);
}
