using System;
using System.Collections.Generic;
using VPNToggle;
using Xunit;

public class StatusPolicyTests
{
    const string ConnectedStats =
        "Cisco Secure Client (version 5.1.21.2728) release.\r\n" +
        "  >> state: Unknown\r\n" +
        "  >> state: Connected\r\n" +
        "  >> state: Connected\r\n" +
        "  >> registered with local VPN subsystem.\r\n" +
        "VPN>   >> notice: Connected to vpn-gate.b-tu.de.\r\n" +
        "\r\n" +
        "[ Connection Information ]\r\n" +
        "\r\n" +
        "    Connection State:            Connected\r\n" +
        "    Tunnel Mode (IPv4):          Tunnel All Traffic\r\n" +
        "    Duration:                    00:09:29\r\n" +
        "    Management Connection State: Disconnected (user tunnel active)\r\n" +
        "\r\n" +
        "[ Address Information ]\r\n" +
        "\r\n" +
        "    Client Address (IPv4):       141.43.0.10\r\n" +
        "    Client Address (IPv6):       Not Available\r\n" +
        "    Server Address:              141.43.0.1\r\n";

    const string DisconnectedStats =
        "  >> state: Unknown\n" +
        "  >> state: Disconnected\n" +
        "  >> notice: Ready to connect.\n" +
        "\n" +
        "[ Connection Information ]\n" +
        "\n" +
        "    Connection State:            Disconnected\n" +
        "    Duration:                    00:00:00\n" +
        "    Management Connection State: Disconnected (user tunnel inactive)\n" +
        "\n" +
        "    Client Address (IPv4):       Not Available\n";

    static readonly DateTime T0 = new DateTime(2026, 11, 16, 12, 0, 0);

    [Fact] public void ConnectedStatsRead() =>
        Assert.Equal(new StatusReading(VpnState.Connected, "141.43.0.10", 569), StatusPolicy.ReadingFromStats(ConnectedStats));

    [Fact] public void DisconnectedStatsRead() =>
        Assert.Equal(new StatusReading(VpnState.Disconnected, null, 0), StatusPolicy.ReadingFromStats(DisconnectedStats));

    [Fact] public void ManagementLineDoesNotDecideTheState() =>
        Assert.Null(StatusPolicy.ReadingFromStats("    Management Connection State: Disconnected (user tunnel active)\n").State);

    [Fact] public void BannerUsedWhenTheTableIsMissing() =>
        Assert.Equal(VpnState.Connected, StatusPolicy.ReadingFromStats("  >> state: Unknown\n  >> state: Connected\n").State);

    [Fact] public void OtherTableStateIsBusy() =>
        Assert.Equal(VpnState.Busy, StatusPolicy.ReadingFromStats("    Connection State:            Reconnecting\n").State);

    [Theory]
    [InlineData("")]
    [InlineData("Cisco Secure Client (vpncli.exe) was not found.")]
    public void OutputWithoutStateGivesNone(string output) =>
        Assert.Null(StatusPolicy.ReadingFromStats(output).State);

    [Fact] public void BannerLastStateLineWins() =>
        Assert.Equal(VpnState.Disconnected, StatusPolicy.StateFromBanner("  >> state: Unknown\n  >> state: Disconnected\n"));

    [Fact] public void BannerConnectingIsBusy() =>
        Assert.Equal(VpnState.Busy, StatusPolicy.StateFromBanner("  >> state: Connecting\n"));

    [Fact] public void BannerWithoutStateLine() =>
        Assert.Null(StatusPolicy.StateFromBanner("VPN> \n"));

    [Theory]
    [InlineData("00:12:05", 725)]
    [InlineData("1 day(s) 02:03:04", 93784)]
    public void DurationParsed(string text, int seconds) =>
        Assert.Equal(seconds, StatusPolicy.SecondsFromDuration(text));

    [Fact] public void MalformedDurationIgnored() =>
        Assert.Null(StatusPolicy.SecondsFromDuration("soon"));

    [Fact] public void SettledWhenConnectedWithTheAddressUp() =>
        Assert.True(StatusPolicy.Settled(VpnState.Connected, "141.43.0.10", new HashSet<string> { "141.43.0.10" }));

    [Fact] public void UnsettledWhenTheAddressIsGone() =>
        Assert.False(StatusPolicy.Settled(VpnState.Connected, "141.43.0.10", new HashSet<string>()));

    [Fact] public void UnsettledWithoutAKnownAddress() =>
        Assert.False(StatusPolicy.Settled(VpnState.Connected, null, new HashSet<string> { "141.43.0.10" }));

    [Fact] public void SettledWhenDisconnected() =>
        Assert.True(StatusPolicy.Settled(VpnState.Disconnected, null, new HashSet<string>()));

    [Theory]
    [InlineData(VpnState.Busy)]
    [InlineData(VpnState.Unknown)]
    public void UnsettledWhileUnclear(VpnState state) =>
        Assert.False(StatusPolicy.Settled(state, null, new HashSet<string>()));

    [Theory]
    [InlineData(true, true, 30)]
    [InlineData(false, true, 3)]
    [InlineData(true, false, 3)]
    public void PollIntervals(bool settled, bool watching, int seconds) =>
        Assert.Equal(TimeSpan.FromSeconds(seconds), StatusPolicy.PollInterval(settled, watching));

    [Theory]
    [InlineData(VpnState.Disconnected, true, 120)]
    [InlineData(VpnState.Disconnected, false, 15)]
    [InlineData(VpnState.Connected, true, 15)]
    [InlineData(VpnState.Busy, true, 5)]
    [InlineData(VpnState.Unknown, true, 5)]
    public void CliIntervals(VpnState state, bool watching, int seconds) =>
        Assert.Equal(TimeSpan.FromSeconds(seconds), StatusPolicy.CliInterval(state, watching));

    [Theory]
    [InlineData(false, false, false, 0, false)]
    [InlineData(true, false, false, 0, true)]
    [InlineData(false, true, false, 0, true)]
    [InlineData(false, false, true, 0, true)]
    [InlineData(false, false, false, 120, true)]
    public void CliNeeded(bool force, bool changed, bool lostTunnel, double secondsLater, bool expected) =>
        Assert.Equal(expected, StatusPolicy.NeedsCli(force, changed, lostTunnel, T0.AddSeconds(secondsLater), T0.AddSeconds(120)));

    [Theory]
    [InlineData("  >> contacting host (vpn-gate.b-tu.de) for login information...", "Contacting the server")]
    [InlineData("  >> notice: Establishing VPN session...", "Starting the session")]
    [InlineData("  >> notice: The Cisco Secure Client - Downloader is performing update checks...", "Checking for Cisco updates")]
    [InlineData("  >> notice: Checking for profile updates...", "Checking for Cisco updates")]
    [InlineData("  >> notice: Downloading Cisco Secure Client - Network Visibility 5.1.21.2728 - 72%", "Updating Cisco Secure Client (72%)")]
    [InlineData("  >> notice: Downloading Cisco Secure Client - Network Visibility 5.1.21.2728", "Updating Cisco Secure Client")]
    [InlineData("  >> notice: Establishing VPN - Initiating connection...", "Opening the tunnel")]
    [InlineData("  >> notice: Establishing VPN - Examining system...", "Checking this computer")]
    [InlineData("  >> notice: Establishing VPN - Activating VPN adapter...", "Activating the VPN adapter")]
    [InlineData("  >> notice: Establishing VPN - Configuring system...", "Configuring the network")]
    [InlineData("  >> notice: Establishing VPN...", null)]
    [InlineData("  >> state: Connecting", null)]
    [InlineData("  >> Bitte geben Sie den zweiten Faktor ein (2FA Token)!", null)]
    public void ConnectSteps(string line, string? expected) =>
        Assert.Equal(expected, StatusPolicy.ConnectStep(line));

    [Theory]
    [InlineData(2, false, "Reconnect when you are ready")]
    [InlineData(0, true, "Reconnecting automatically")]
    [InlineData(2, true, "Reconnecting automatically, attempt 2 of 4")]
    public void ReconnectNotes(int attempt, bool auto, string expected) =>
        Assert.Equal(expected, StatusPolicy.ReconnectNote(attempt, 4, auto));
}
