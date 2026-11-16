using System;
using Xunit;

public class UpdatePolicyTests
{
    static readonly DateTime T0 = new DateTime(2026, 11, 16, 11, 15, 4, DateTimeKind.Utc);
    const string ReleasePage = "https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.6";

    [Theory]
    [InlineData("v1.10", "1.9")]
    [InlineData("v1.6", "1.5")]
    [InlineData("v1.5.1", "1.5")]
    [InlineData("v2.0", "1.99.99")]
    [InlineData("v1.6", "v1.5")]
    [InlineData("V1.6", "1.5")]
    [InlineData("1.6", "1.5")]
    [InlineData(" v1.6\n", "1.5")]
    [InlineData("v1.06", "1.5")]
    [InlineData("v1.6", "1.5.0.0")]
    public void NewerReleaseIsNewer(string latest, string current) =>
        Assert.True(UpdatePolicy.IsNewer(latest, current));

    [Theory]
    [InlineData("v1.9", "1.10")]
    [InlineData("v1.5", "1.5")]
    [InlineData("v1.5.0", "1.5")]
    [InlineData("1.5", "v1.5.0")]
    [InlineData("v1.5", "1.5.0.0")]
    [InlineData("v1.4", "1.5")]
    public void SameOrOlderReleaseIsNotNewer(string latest, string current) =>
        Assert.False(UpdatePolicy.IsNewer(latest, current));

    [Theory]
    [InlineData("")]
    [InlineData("v")]
    [InlineData("latest")]
    [InlineData("v1.6-beta")]
    [InlineData("v1..6")]
    [InlineData("v1.6.")]
    [InlineData("v1.+6")]
    [InlineData("vv1.6")]
    [InlineData("v99999999999999999999.0")]
    [InlineData(null)]
    public void MalformedTagIsNotNewer(string? latest) =>
        Assert.False(UpdatePolicy.IsNewer(latest, "1.5"));

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void UnknownRunningVersionIsNeverOutdated(string? current) =>
        Assert.False(UpdatePolicy.IsNewer("v1.6", current));

    [Fact] public void DisplayStripsThePrefix() =>
        Assert.Equal("1.6", UpdatePolicy.DisplayVersion("v1.6"));

    [Fact] public void DisplayKeepsMalformedTag() =>
        Assert.Equal("nightly", UpdatePolicy.DisplayVersion("nightly"));

    [Fact] public void FirstCheckRuns() =>
        Assert.True(UpdatePolicy.ShouldCheck(T0, null));

    [Theory]
    [InlineData(3600)]
    [InlineData(86399)]
    public void WithinADayWaits(double seconds) =>
        Assert.False(UpdatePolicy.ShouldCheck(T0.AddSeconds(seconds), T0));

    [Fact] public void ADayLaterRuns() =>
        Assert.True(UpdatePolicy.ShouldCheck(T0.AddSeconds(86400), T0));

    [Fact] public void ClockSetBackRuns() =>
        Assert.True(UpdatePolicy.ShouldCheck(T0.AddSeconds(-10), T0));

    [Fact] public void BannerForNewerRelease() =>
        Assert.True(UpdatePolicy.ShowsBanner("v1.6", "1.5", null));

    [Fact] public void NoBannerWhenCurrent() =>
        Assert.False(UpdatePolicy.ShowsBanner("v1.5", "1.5", null));

    [Fact] public void NoBannerBeforeAnyCheck() =>
        Assert.False(UpdatePolicy.ShowsBanner(null, "1.5", null));

    [Fact] public void NoBannerForDismissedRelease() =>
        Assert.False(UpdatePolicy.ShowsBanner("v1.6", "1.5", "v1.6"));

    [Fact] public void DismissalMatchesAcrossSpellings() =>
        Assert.False(UpdatePolicy.ShowsBanner("v1.6.0", "1.5", "1.6"));

    [Fact] public void BannerReturnsForLaterRelease() =>
        Assert.True(UpdatePolicy.ShowsBanner("v1.7", "1.5", "v1.6"));

    [Fact] public void NoBannerForMalformedTag() =>
        Assert.False(UpdatePolicy.ShowsBanner("nightly", "1.5", null));

    [Fact] public void ReleasePageKept() =>
        Assert.Equal(ReleasePage, UpdatePolicy.Page(ReleasePage));

    [Theory]
    [InlineData("https://example.com/VPNToggle/releases/tag/v1.6")]
    [InlineData("https://github.com.example.com/alwinpaul1/VPNToggle/releases/tag/v1.6")]
    [InlineData("file:///C:/Windows/System32/calc.exe")]
    [InlineData("https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.6 --flag")]
    [InlineData(null)]
    public void UntrustedPageReplaced(string? candidate) =>
        Assert.Equal(UpdatePolicy.ReleasesPage, UpdatePolicy.Page(candidate));

    [Fact] public void ReleaseParsed() =>
        Assert.Equal(new ReleaseInfo("v1.6", ReleasePage), UpdatePolicy.ReleaseFromJson(
            "{\"tag_name\":\"v1.6\",\"html_url\":\"" + ReleasePage + "\",\"draft\":false,\"prerelease\":false}"));

    [Fact] public void ReleaseWithoutPageFallsBack() =>
        Assert.Equal(new ReleaseInfo("v1.6", UpdatePolicy.ReleasesPage), UpdatePolicy.ReleaseFromJson("{\"tag_name\":\"v1.6\"}"));

    [Theory]
    [InlineData("{\"tag_name\":\"v1.6\",\"prerelease\":true}")]
    [InlineData("{\"tag_name\":\"v1.6\",\"draft\":true}")]
    [InlineData("{\"tag_name\":\"nightly\"}")]
    [InlineData("{\"tag_name\":16}")]
    [InlineData("{\"message\":\"API rate limit exceeded\"}")]
    [InlineData("<html>")]
    [InlineData("[]")]
    [InlineData("")]
    public void UnusableAnswerIgnored(string json) =>
        Assert.Null(UpdatePolicy.ReleaseFromJson(json));
}
