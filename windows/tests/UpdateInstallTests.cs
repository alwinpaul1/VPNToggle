using System;
using System.Linq;
using Xunit;

public class UpdateInstallTests
{
    const string Base = "https://github.com/alwinpaul1/VPNToggle/releases/download/";
    static readonly string Hash = string.Concat(Enumerable.Repeat("ab", 32));
    static readonly string GoodDigest = "sha256:" + Hash;

    static string Release(string tag = "v1.9", string name = "VPNToggle.exe", string? url = null, string? digest = "default",
        long size = 1000, string extra = "", string flags = "")
    {
        var link = url ?? Base + tag + "/" + name;
        var d = digest == "default" ? GoodDigest : digest;
        var digestField = d == null ? "" : $"\"digest\": \"{d}\",";
        return "{" + flags + $"\"tag_name\": \"{tag}\", \"html_url\": \"https://github.com/alwinpaul1/VPNToggle/releases/tag/{tag}\", " +
            $"\"assets\": [{{\"name\": \"{name}\", {digestField} \"size\": {size}, \"browser_download_url\": \"{link}\"}}{extra}]}}";
    }

    static UpdateRefusalKind? Kind(string json, string current = "1.8", UpdateSource? source = null) =>
        UpdatePolicy.Plan(json, current, UpdatePolicy.WindowsAsset, source).refusal?.Kind;

    [Theory]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/VPNToggle.exe", true)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/", false)]
    [InlineData("http://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/VPNToggle.exe", false)]
    [InlineData("https://github.com/someone/VPNToggle/releases/download/v1.9/VPNToggle.exe", false)]
    [InlineData("https://github.com.example.org/alwinpaul1/VPNToggle/releases/download/v1.9/VPNToggle.exe", false)]
    [InlineData("https://github.com@example.org/alwinpaul1/VPNToggle/releases/download/v1.9/VPNToggle.exe", false)]
    [InlineData("https://x@github.com/alwinpaul1/VPNToggle/releases/download/v1.9/VPNToggle.exe", false)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/../../../../evil/a.exe", false)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/%2e%2e/%2E%2E/a.exe", false)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9%2Fa.exe", false)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/a .exe", false)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9\\a.exe", false)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.9", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void DownloadUrlAllowList(string? url, bool allowed) =>
        Assert.Equal(allowed, UpdatePolicy.DownloadAllowed(url));

    [Theory]
    [InlineData("https://objects.githubusercontent.com/github-production-release-asset/1/2?sig=3", true)]
    [InlineData("https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r", true)]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/VPNToggle.exe", true)]
    [InlineData("https://example.org/a.exe", false)]
    [InlineData("http://objects.githubusercontent.com/a", false)]
    [InlineData("https://objects.githubusercontent.com.example.org/a", false)]
    [InlineData("https://x.objects.githubusercontent.com/a", false)]
    public void RedirectAllowList(string url, bool allowed) =>
        Assert.Equal(allowed, UpdatePolicy.RedirectAllowed(url));

    [Fact] public void DigestParsed() => Assert.Equal(Hash, UpdatePolicy.Sha256FromDigest(GoodDigest));

    [Fact] public void UpperCaseDigestLowered() => Assert.Equal(Hash, UpdatePolicy.Sha256FromDigest("sha256:" + Hash.ToUpperInvariant()));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("sha1:abababababababababababababababababababab")]
    [InlineData("sha256:abcd")]
    [InlineData("sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")]
    [InlineData("abababababababababababababababababababababababababababababababab")]
    public void BadDigestsRefused(string? digest) => Assert.Null(UpdatePolicy.Sha256FromDigest(digest));

    [Fact] public void TooLongDigestRefused() => Assert.Null(UpdatePolicy.Sha256FromDigest(GoodDigest + "ab"));

    [Fact] public void EqualDigestsMatchAcrossCase() => Assert.True(UpdatePolicy.DigestMatches(Hash, Hash.ToUpperInvariant()));

    [Fact] public void OneCharacterOffDoesNotMatch() => Assert.False(UpdatePolicy.DigestMatches(Hash, Hash.Substring(0, 62) + "ac"));

    [Fact] public void EmptyDigestNeverMatches() => Assert.False(UpdatePolicy.DigestMatches("", ""));

    [Fact] public void NewerReleaseWithDigestPlanned()
    {
        var (plan, refusal) = UpdatePolicy.Plan(Release(), "1.8", UpdatePolicy.WindowsAsset);
        Assert.Null(refusal);
        Assert.Equal(new UpdatePlan("v1.9", Base + "v1.9/VPNToggle.exe", Hash, 1000), plan);
    }

    [Fact] public void SameVersionNotPlanned() => Assert.Equal(UpdateRefusalKind.NotNewer, Kind(Release(tag: "v1.8")));

    [Fact] public void OlderReleaseNotPlanned() => Assert.Equal(UpdateRefusalKind.NotNewer, Kind(Release(tag: "v1.7")));

    [Fact] public void UnknownRunningVersionNotPlanned() => Assert.Equal(UpdateRefusalKind.NotNewer, Kind(Release(), current: ""));

    [Fact] public void OtherPlatformAssetOnly() => Assert.Equal(UpdateRefusalKind.NoAsset, Kind(Release(name: "VPNToggle-macOS.zip")));

    [Fact] public void AssetNameMustMatchExactly() => Assert.Equal(UpdateRefusalKind.NoAsset, Kind(Release(name: "VPNToggle.exe.zip")));

    [Fact] public void TwoAssetsWithTheNameRefused()
    {
        var twin = $", {{\"name\": \"VPNToggle.exe\", \"digest\": \"{GoodDigest}\", \"size\": 5, \"browser_download_url\": \"{Base}v1.9/other.exe\"}}";
        Assert.Equal(UpdateRefusalKind.NoAsset, Kind(Release(extra: twin)));
    }

    [Fact] public void DownloadFromAnotherHostRefused() =>
        Assert.Equal(UpdateRefusalKind.UrlNotAllowed, Kind(Release(url: "https://example.org/VPNToggle.exe")));

    [Fact] public void NoDigestRefused() => Assert.Equal(UpdateRefusalKind.MissingDigest, Kind(Release(digest: null)));

    [Fact] public void MalformedDigestRefused() => Assert.Equal(UpdateRefusalKind.MissingDigest, Kind(Release(digest: "sha256:123")));

    [Fact] public void ZeroSizeRefused() => Assert.Equal(UpdateRefusalKind.TooLarge, Kind(Release(size: 0)));

    [Fact] public void OversizedRefused() => Assert.Equal(UpdateRefusalKind.TooLarge, Kind(Release(size: UpdatePolicy.MaxAssetBytes + 1)));

    [Fact] public void UnreadableAnswerRefused() => Assert.Equal(UpdateRefusalKind.NoRelease, Kind("<html>"));

    [Fact] public void PrereleaseRefused() => Assert.Equal(UpdateRefusalKind.NoRelease, Kind(Release(flags: "\"prerelease\": true, ")));

    [Fact] public void NothingSetIsProduction() => Assert.Same(UpdatePolicy.Production, UpdatePolicy.Source(null));

    [Theory]
    [InlineData("http://example.org:8123/latest.json")]
    [InlineData("https://example.org/latest.json")]
    [InlineData("http://127.0.0.1/latest.json")]
    [InlineData("http://127.0.0.1.example.org:8123/latest.json")]
    [InlineData("https://127.0.0.1:8123/latest.json")]
    [InlineData("http://user@127.0.0.1:8123/latest.json")]
    [InlineData("not a url")]
    public void OnlyLoopbackTestServersAccepted(string api) => Assert.Same(UpdatePolicy.Production, UpdatePolicy.Source(api));

    [Fact] public void LoopbackTestServerAllowsOnlyItself()
    {
        var local = UpdatePolicy.Source("http://127.0.0.1:8123/latest.json");
        Assert.Equal("http://127.0.0.1:8123/", local.DownloadPrefix);
        Assert.True(UpdatePolicy.DownloadAllowed("http://127.0.0.1:8123/VPNToggle.exe", local));
        Assert.False(UpdatePolicy.DownloadAllowed("http://127.0.0.1:9999/VPNToggle.exe", local));
        Assert.False(UpdatePolicy.DownloadAllowed("http://127.0.0.1:81234/VPNToggle.exe", local));
        Assert.False(UpdatePolicy.DownloadAllowed(Base + "v1.9/VPNToggle.exe", local));
        Assert.False(UpdatePolicy.RedirectAllowed("http://objects.githubusercontent.com/a", local));
    }

    [Fact] public void NewerProgramOfTheTaggedVersionAccepted() =>
        Assert.Null(UpdatePolicy.ContentRefusal(true, "1.9.0.0", "1.8", "v1.9"));

    [Fact] public void FileThatIsNoProgramRefused() =>
        Assert.Equal(UpdateRefusalKind.WrongApp, UpdatePolicy.ContentRefusal(false, "1.9", "1.8", "v1.9")?.Kind);

    [Fact] public void ProgramOlderThanTheTagSaysRefused() =>
        Assert.Equal(UpdateRefusalKind.WrongApp, UpdatePolicy.ContentRefusal(true, "1.9", "1.8", "v2.0")?.Kind);

    [Fact] public void ProgramNotNewerThanTheRunningOneRefused() =>
        Assert.Equal(UpdateRefusalKind.WrongApp, UpdatePolicy.ContentRefusal(true, "1.8", "1.8", "v1.8")?.Kind);

    [Fact] public void ProgramWithoutAVersionRefused() =>
        Assert.Equal(UpdateRefusalKind.WrongApp, UpdatePolicy.ContentRefusal(true, null, "1.8", "v1.9")?.Kind);

    [Theory]
    [InlineData(UpdatePhase.Idle, UpdateEvent.Start, UpdatePhase.Checking)]
    [InlineData(UpdatePhase.Checking, UpdateEvent.Planned, UpdatePhase.Downloading)]
    [InlineData(UpdatePhase.Downloading, UpdateEvent.Downloaded, UpdatePhase.Verifying)]
    [InlineData(UpdatePhase.Verifying, UpdateEvent.Verified, UpdatePhase.Installing)]
    [InlineData(UpdatePhase.Installing, UpdateEvent.Installed, UpdatePhase.Relaunching)]
    [InlineData(UpdatePhase.Checking, UpdateEvent.Installed, UpdatePhase.Checking)]
    [InlineData(UpdatePhase.Idle, UpdateEvent.Installed, UpdatePhase.Idle)]
    [InlineData(UpdatePhase.Downloading, UpdateEvent.Start, UpdatePhase.Downloading)]
    [InlineData(UpdatePhase.Downloading, UpdateEvent.Refused, UpdatePhase.Failed)]
    [InlineData(UpdatePhase.Idle, UpdateEvent.Refused, UpdatePhase.Idle)]
    [InlineData(UpdatePhase.Failed, UpdateEvent.Start, UpdatePhase.Checking)]
    [InlineData(UpdatePhase.Failed, UpdateEvent.Reset, UpdatePhase.Idle)]
    [InlineData(UpdatePhase.Relaunching, UpdateEvent.Refused, UpdatePhase.Relaunching)]
    public void FlowSteps(UpdatePhase phase, UpdateEvent e, UpdatePhase expected) =>
        Assert.Equal(expected, UpdatePolicy.Next(phase, e));

    [Theory]
    [InlineData(UpdatePhase.Idle, false)]
    [InlineData(UpdatePhase.Failed, false)]
    [InlineData(UpdatePhase.Downloading, true)]
    [InlineData(UpdatePhase.Relaunching, true)]
    public void BusyPhases(UpdatePhase phase, bool busy) => Assert.Equal(busy, UpdatePolicy.Busy(phase));

    [Theory]
    [InlineData(UpdatePhase.Idle, "Install update")]
    [InlineData(UpdatePhase.Failed, "Install update")]
    [InlineData(UpdatePhase.Downloading, "Downloading…")]
    [InlineData(UpdatePhase.Installing, "Installing…")]
    public void ButtonTitles(UpdatePhase phase, string title) => Assert.Equal(title, UpdatePolicy.ButtonTitle(phase));

    [Fact] public void EveryRefusalHasItsOwnSentence()
    {
        var kinds = Enum.GetValues<UpdateRefusalKind>();
        var messages = kinds.Select(k => UpdatePolicy.Message(new UpdateRefusal(k, "x"))).ToList();
        Assert.Equal(kinds.Length, messages.Distinct().Count());
        Assert.All(messages, m => Assert.False(string.IsNullOrWhiteSpace(m)));
    }

    [Fact] public void SwapPaths()
    {
        Assert.Equal("C:\\Apps\\VPNToggle.exe.old", UpdatePolicy.OldPath("C:\\Apps\\VPNToggle.exe"));
        Assert.Equal("C:\\Apps\\VPNToggle.exe.new", UpdatePolicy.NewPath("C:\\Apps\\VPNToggle.exe"));
    }

    [Theory]
    [InlineData("1.8", "1.9", true)]
    [InlineData("1.9.0.0", "1.9", false)]
    [InlineData("1.9", "1.9", false)]
    [InlineData(null, "1.9", false)]
    [InlineData("1.8", "", false)]
    public void PauseCopyStaleness(string? copy, string running, bool stale) =>
        Assert.Equal(stale, UpdatePolicy.CopyStale(copy, running));
}
