using System;
using Xunit;

public class ConnectPolicyTests
{
    static readonly DateTime T0 = new DateTime(2026, 11, 16, 11, 15, 4);
    static DateTime At(double s) => T0.AddSeconds(s);

    const string UpgradeLog =
        "  >> state: Connecting\n" +
        "  >> notice: Establishing VPN session...\n" +
        "  >> notice: The Cisco Secure Client - Downloader is performing update checks...\n" +
        "  >> notice: Downloading Cisco Secure Client - Network Visibility 5.1.21.2728 - 72%\n";

    [Fact] public void FreshConnectKeepsWaiting() =>
        Assert.Null(ConnectPolicy.TimeoutReason(At(0), T0, T0));

    [Fact] public void Quiet89SecondsKeepsWaiting() =>
        Assert.Null(ConnectPolicy.TimeoutReason(At(89), T0, T0));

    [Fact] public void Quiet90SecondsStops() =>
        Assert.Equal("Cisco stopped responding for 90 s.", ConnectPolicy.TimeoutReason(At(90), T0, T0));

    [Theory]
    [InlineData(180)]
    [InlineData(600)]
    public void DownloadPrintingProgressKeepsWaiting(double seconds) =>
        Assert.Null(ConnectPolicy.TimeoutReason(At(seconds), T0, At(seconds - 1)));

    [Fact] public void HardLimitStopsEvenWhileOutputContinues() =>
        Assert.Equal("Gave up after 15 minutes.", ConnectPolicy.TimeoutReason(At(900), T0, At(899)));

    [Fact] public void HardLimitWinsOverIdle() =>
        Assert.Equal("Gave up after 15 minutes.", ConnectPolicy.TimeoutReason(At(1000), T0, T0));

    [Fact] public void CustomLimitsApply() =>
        Assert.Equal("Cisco stopped responding for 5 s.",
            ConnectPolicy.TimeoutReason(At(5), T0, T0, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(60)));

    [Fact] public void ServiceStoppedDetected() =>
        Assert.True(ConnectPolicy.ServiceStopped("  >> notice: The VPN service was stopped\n"));

    [Fact] public void NormalLogIsNotServiceStopped() =>
        Assert.False(ConnectPolicy.ServiceStopped(UpgradeLog));

    [Fact] public void CliErrorLineWins() =>
        Assert.Equal("The requested authentication type is not supported",
            ConnectPolicy.FailureMessage(UpgradeLog + "  >> error: The requested authentication type is not supported\n",
                "vpn-gate.b-tu.de", "Cisco stopped responding for 90 s."));

    [Fact] public void ServiceStoppedReportsUpdate() =>
        Assert.Equal(ConnectPolicy.UpdatingMessage,
            ConnectPolicy.FailureMessage("  >> notice: The VPN service was stopped\n", "h", null));

    [Fact] public void DownloadInProgressReportsUpdate() =>
        Assert.Equal(ConnectPolicy.UpdatingMessage, ConnectPolicy.FailureMessage(UpgradeLog, "h", "Gave up after 15 minutes."));

    [Fact] public void InstallStepReportsUpdate() =>
        Assert.Equal(ConnectPolicy.UpdatingMessage,
            ConnectPolicy.FailureMessage("  >> notice: Performing any required updates...\n", "h", null));

    [Fact] public void TimeoutReasonUsedWhenNothingElseExplainsIt() =>
        Assert.Equal("Cisco stopped responding for 90 s.",
            ConnectPolicy.FailureMessage("  >> state: Connecting\n", "h", "Cisco stopped responding for 90 s."));

    [Fact] public void GenericMessageWhenCliJustExits() =>
        Assert.Equal("Could not connect to vpn-gate.b-tu.de.",
            ConnectPolicy.FailureMessage("  >> state: Disconnected\n", "vpn-gate.b-tu.de", null));
}
