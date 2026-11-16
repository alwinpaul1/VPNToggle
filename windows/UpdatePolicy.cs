using System;
using System.Globalization;
using System.Linq;
using System.Text.Json;

public sealed record ReleaseInfo(string Tag, string Page);

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
}
