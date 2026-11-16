using System;
using VPNToggle;
using Xunit;

public class StatusSessionTests
{
    const string Banner =
        "Cisco Secure Client (version 5.1.21.2728) release.\r\n" +
        "\r\n" +
        "Copyright (c) 2004 - 2026, Cisco Systems, Inc. All rights reserved.\r\n" +
        "\r\n";

    const string ConnectedSession = Banner +
        "  >> state: Unknown\r\n" +
        "VPN>   >> state: Connected\r\n" +
        "VPN>   >> state: Connected\r\n" +
        "VPN>   >> registered with local VPN subsystem.\r\n" +
        "VPN>   >> notice: Connected to vpn.example.org.\r\n" +
        "VPN> \r\n" +
        "[ Connection Information ]\r\n" +
        "\r\n" +
        "    Connection State:            Connected\r\n" +
        "    Tunnel Mode (IPv4):          Tunnel All Traffic\r\n" +
        "    Duration:                    1 day 02:03:04\r\n" +
        "    Management Connection State: Disconnected (user tunnel active)\r\n" +
        "\r\n" +
        "[ Address Information ]\r\n" +
        "\r\n" +
        "    Client Address (IPv4):       10.20.30.40\r\n" +
        "    Client Address (IPv6):       Not Available\r\n" +
        "    Server Address:              192.0.2.1\r\n" +
        "\r\n" +
        "[ Secured Routes (IPv6) ]\r\n" +
        "\r\n";

    const string Prompt = "VPN> \r\n";
    const string Complete = ConnectedSession + Prompt;
    const int Duration = ((24 + 2) * 60 + 3) * 60 + 4;

    const string DisconnectedSession = Banner +
        "  >> state: Unknown\r\n" +
        "VPN>   >> state: Disconnected\r\n" +
        "VPN>   >> state: Disconnected\r\n" +
        "VPN>   >> notice: Ready to connect.\r\n" +
        "VPN>   >> registered with local VPN subsystem.\r\n";

    const string Reconnecting = "  >> state: Reconnecting\r\n  >> registered with local VPN subsystem.\r\n";

    static readonly string Incomplete = Complete.Replace("1 day 02:03:04", "Not Available");
    static readonly TimeSpan Soon = TimeSpan.FromMilliseconds(200);
    static readonly TimeSpan Late = TimeSpan.FromSeconds(1);

    [Fact] public void NoStateBeforeTheAgentRegisters() =>
        Assert.Null(StatusPolicy.RegisteredState(Banner + "  >> state: Unknown\r\nVPN>   >> state: Connected\r\n"));

    [Fact] public void ConnectedOnceRegistered() =>
        Assert.Equal(VpnState.Connected, StatusPolicy.RegisteredState(ConnectedSession));

    [Fact] public void DisconnectedOnceRegistered() =>
        Assert.Equal(VpnState.Disconnected, StatusPolicy.RegisteredState(DisconnectedSession));

    [Fact] public void ChangingStateIsBusy() =>
        Assert.Equal(VpnState.Busy, StatusPolicy.RegisteredState(Reconnecting));

    [Fact] public void OnlyUnknownBeforeRegisteringIsBusy() =>
        Assert.Equal(VpnState.Busy, StatusPolicy.RegisteredState("  >> state: Unknown\r\n  >> registered with local VPN subsystem.\r\n"));

    [Fact] public void StateLineAfterTheMarkerDoesNotCount() =>
        Assert.Null(StatusPolicy.RegisteredState("  >> registered with local VPN subsystem.\r\n  >> state: Connected\r\n"));

    [Fact] public void EmptyOutputHasNoState() =>
        Assert.Null(StatusPolicy.RegisteredState(""));

    [Fact] public void SessionStatsRead() =>
        Assert.Equal(new StatusReading(VpnState.Connected, "10.20.30.40", Duration), StatusPolicy.ReadingFromSession(Complete));

    [Fact] public void LineFeedsOnlyAreTolerated() =>
        Assert.Equal("10.20.30.40", StatusPolicy.ReadingFromSession(Complete.Replace("\r\n", "\n")).Ip);

    [Fact] public void LaterDurationReplacesNotAvailable() =>
        Assert.Equal(Duration, StatusPolicy.ReadingFromSession(Incomplete + Complete).Seconds);

    [Fact] public void DisconnectedIsReportedWithoutStats() =>
        Assert.Equal(new StatusReading(VpnState.Disconnected, null, null), StatusPolicy.ReadingFromSession(DisconnectedSession));

    [Fact] public void NonConnectedStateDropsAddressAndDuration() =>
        Assert.Equal(new StatusReading(VpnState.Disconnected, null, null),
            StatusPolicy.ReadingFromSession(DisconnectedSession + "\r\n    Client Address (IPv4):       10.20.30.40\r\n    Duration: 00:00:07\r\n"));

    [Fact] public void RepliesCounted() =>
        Assert.Equal(2, StatusPolicy.SessionReplies(Incomplete + Complete));

    [Fact] public void ReplyWithoutThePromptIsNotCounted() =>
        Assert.Equal(0, StatusPolicy.SessionReplies(ConnectedSession));

    [Fact] public void StepWaitsBeforeRegistering() =>
        Assert.Equal(SessionStep.Wait, StatusPolicy.SessionStepFor(Banner, 1, Soon));

    [Fact] public void StepClosesBlindWhenNothingRegistersInTime() =>
        Assert.Equal(SessionStep.CloseBlind, StatusPolicy.SessionStepFor(Banner, 1, Late));

    [Fact] public void StepClosesBlindOnEmptyOutput() =>
        Assert.Equal(SessionStep.CloseBlind, StatusPolicy.SessionStepFor("", 1, Late));

    [Fact] public void StepDoesNotCloseBlindOnceRegistered() =>
        Assert.Equal(SessionStep.Wait, StatusPolicy.SessionStepFor(ConnectedSession, 1, Late));

    [Fact] public void StepDisconnectedIsDoneWithoutStats() =>
        Assert.Equal(SessionStep.Done, StatusPolicy.SessionStepFor(DisconnectedSession, 1, Soon));

    [Fact] public void StepBusyIsDoneWithoutStats() =>
        Assert.Equal(SessionStep.Done, StatusPolicy.SessionStepFor(Reconnecting, 1, Soon));

    [Fact] public void StepConnectedReplyNotFinished() =>
        Assert.Equal(SessionStep.Wait, StatusPolicy.SessionStepFor(ConnectedSession, 1, Soon));

    [Fact] public void StepConnectedWithDuration() =>
        Assert.Equal(SessionStep.Done, StatusPolicy.SessionStepFor(Complete, 1, Soon));

    [Fact] public void StepConnectedWithoutDurationAsksAgain() =>
        Assert.Equal(SessionStep.AskAgain, StatusPolicy.SessionStepFor(Incomplete, 1, Soon));

    [Fact] public void StepSecondRequestPending() =>
        Assert.Equal(SessionStep.Wait, StatusPolicy.SessionStepFor(Incomplete, 2, Soon));

    [Fact] public void StepSecondReplyCarriesTheDuration() =>
        Assert.Equal(SessionStep.Done, StatusPolicy.SessionStepFor(Incomplete + Complete, 2, Soon));

    [Fact] public void StepOneRetryOnly() =>
        Assert.Equal(SessionStep.Done, StatusPolicy.SessionStepFor(Incomplete + Incomplete, 2, Soon));

    [Fact] public void NothingReadIsNotUsable() =>
        Assert.False(StatusPolicy.SessionUsable(null));

    [Fact] public void NoStateIsNotUsable() =>
        Assert.False(StatusPolicy.SessionUsable(new StatusReading(null, null, null)));

    [Fact] public void UnknownStateIsNotUsable() =>
        Assert.False(StatusPolicy.SessionUsable(new StatusReading(VpnState.Unknown, null, null)));

    [Fact] public void DisconnectedIsUsable() =>
        Assert.True(StatusPolicy.SessionUsable(new StatusReading(VpnState.Disconnected, null, null)));

    [Fact] public void BusyIsUsable() =>
        Assert.True(StatusPolicy.SessionUsable(new StatusReading(VpnState.Busy, null, null)));

    [Fact] public void ConnectedWithAddressAndDurationIsUsable() =>
        Assert.True(StatusPolicy.SessionUsable(StatusPolicy.ReadingFromSession(Complete)));

    [Fact] public void ConnectedWithoutDurationFallsBack() =>
        Assert.False(StatusPolicy.SessionUsable(StatusPolicy.ReadingFromSession(Incomplete)));

    [Fact] public void ConnectedWithoutAddressFallsBack() =>
        Assert.False(StatusPolicy.SessionUsable(new StatusReading(VpnState.Connected, null, 5)));

    [Fact] public void NoCliOutputFallsBack() =>
        Assert.False(StatusPolicy.SessionUsable(StatusPolicy.ReadingFromSession("Cisco Secure Client (vpncli.exe) was not found.")));

    [Theory]
    [InlineData(0, true)]
    [InlineData(1, true)]
    [InlineData(2, false)]
    [InlineData(5, false)]
    public void FastPathStopsAfterTwoFailuresInARow(int failures, bool allowed) =>
        Assert.Equal(allowed, StatusPolicy.SessionAllowed(failures));
}
